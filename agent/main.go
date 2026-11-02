package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	_ "embed"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf16"
)

//go:embed Collect-HyperVSnapshot.ps1
var collector string

var version = "dev"

type config struct {
	Bind      string `json:"bind"`
	Port      int    `json:"port"`
	Token     string `json:"token"`
	Interval  int    `json:"intervalSeconds"`
	TLSCert   string `json:"tlsCert,omitempty"`
	TLSKey    string `json:"tlsKey,omitempty"`
	AllowHTTP bool   `json:"allowRemoteHttp"`
}

func defaultPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatal(err)
	}
	return filepath.Join(home, ".homarr-hyperv-monitor", "config.json")
}

func (c config) validate() error {
	ip := net.ParseIP(c.Bind)
	if ip == nil {
		return errors.New("bind must be an IP address")
	}
	if c.Port < 1 || c.Port > 65535 {
		return errors.New("port must be 1–65535")
	}
	if c.Interval < 5 || c.Interval > 20 {
		return errors.New("interval must be 5–20 seconds")
	}
	if !regexp.MustCompile(`^[A-Za-z0-9_-]{32,256}$`).MatchString(c.Token) {
		return errors.New("token must contain 32–256 URL-safe characters")
	}
	if (c.TLSCert == "") != (c.TLSKey == "") {
		return errors.New("tls-cert and tls-key must be specified together")
	}
	if c.TLSCert == "" && !ip.IsLoopback() && !c.AllowHTTP {
		return errors.New("remote listeners require TLS; use --allow-remote-http only on a trusted private network")
	}
	return nil
}

func loadConfig(path string) (config, error) {
	var c config
	f, err := os.Open(path)
	if err != nil {
		return c, err
	}
	defer f.Close()
	d := json.NewDecoder(io.LimitReader(f, 65537))
	d.DisallowUnknownFields()
	if err := d.Decode(&c); err != nil {
		return c, err
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return c, errors.New("unexpected data after config")
	}
	for _, p := range []*string{&c.TLSCert, &c.TLSKey} {
		if *p != "" && !filepath.IsAbs(*p) {
			*p = filepath.Join(filepath.Dir(path), *p)
		}
	}
	return c, c.validate()
}

func powershell(ctx context.Context, script string) *exec.Cmd {
	u := utf16.Encode([]rune(script))
	b := make([]byte, len(u)*2)
	for i, v := range u {
		binary.LittleEndian.PutUint16(b[2*i:], v)
	}
	cmd := exec.CommandContext(ctx, filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"), "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", base64.StdEncoding.EncodeToString(b))
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	// A PowerShell 7 parent can export incompatible module paths to Windows PowerShell 5.1.
	for _, entry := range os.Environ() {
		name, _, _ := strings.Cut(entry, "=")
		if !strings.EqualFold(name, "PSModulePath") {
			cmd.Env = append(cmd.Env, entry)
		}
	}
	cmd.WaitDelay = time.Second * 2
	return cmd
}

func quotePS(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

// Restrict the dedicated config directory before creating token/private-key files.
func protectDirectory(path string) error {
	if err := os.MkdirAll(path, 0700); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	script := `$ProgressPreference='SilentlyContinue'; $ErrorActionPreference='Stop'; $acl=New-Object Security.AccessControl.DirectorySecurity; $acl.SetAccessRuleProtection($true,$false); $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User; $acl.SetOwner($sid); foreach($s in (@($sid.Value,'S-1-5-18','S-1-5-32-544') | Select-Object -Unique)) { $id=New-Object Security.Principal.SecurityIdentifier($s); $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($id,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))) }; Set-Acl -LiteralPath ` + quotePS(path) + ` -AclObject $acl`
	cmd := powershell(ctx, script)
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("protect configuration directory: %w", err)
	}
	return nil
}

func writePrivate(path string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".hyperv-*")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	if _, err = f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}

func generateTLS(dir, bind string) (string, string, error) {
	ip := net.ParseIP(bind)
	if ip == nil || ip.IsUnspecified() {
		return "", "", errors.New("generate-tls needs a specific bind IP; wildcard listeners need an existing certificate")
	}
	certPath, keyPath := filepath.Join(dir, "server.crt"), filepath.Join(dir, "server.key")
	for _, p := range []string{certPath, keyPath} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			return "", "", errors.New("TLS files already exist; use --tls-cert and --tls-key to reuse them")
		}
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return "", "", err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return "", "", err
	}
	template := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "Homarr Hyper-V Agent"}, NotBefore: time.Now().Add(-5 * time.Minute), NotAfter: time.Now().AddDate(2, 0, 0), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, IPAddresses: []net.IP{ip}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return "", "", err
	}
	private, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return "", "", err
	}
	if err := writePrivate(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private})); err != nil {
		return "", "", err
	}
	if err := writePrivate(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})); err != nil {
		return "", "", err
	}
	return certPath, keyPath, nil
}

func configure(args []string) error {
	f := flag.NewFlagSet("configure", flag.ContinueOnError)
	path := f.String("config", defaultPath(), "configuration file")
	bind := f.String("bind", "127.0.0.1", "listener IP (IPv4 or IPv6)")
	port := f.Int("port", 9276, "listener port")
	token := f.String("token", "", "API token; generated randomly when omitted")
	tokenFile := f.String("token-file", "", "read API token from a file (avoids shell history)")
	interval := f.Int("interval", 10, "collection interval in seconds, 5–20")
	cert := f.String("tls-cert", "", "PEM server certificate")
	key := f.String("tls-key", "", "PEM private key")
	generate := f.Bool("generate-tls", false, "generate a self-signed TLS certificate for bind IP")
	allowHTTP := f.Bool("allow-remote-http", false, "explicitly allow unencrypted private-network access")
	force := f.Bool("force", false, "replace existing config (omitted values reset to defaults)")
	if err := f.Parse(args); err != nil {
		return err
	}
	if f.NArg() != 0 {
		return errors.New("unexpected configure arguments")
	}
	abs, err := filepath.Abs(*path)
	if err != nil {
		return err
	}
	*path = abs
	if _, err := os.Stat(*path); err == nil && !*force {
		return errors.New("configuration already exists; use --force to replace it, or edit it directly")
	}
	if *token != "" && *tokenFile != "" {
		return errors.New("choose token or token-file")
	}
	if *tokenFile != "" {
		b, e := os.ReadFile(*tokenFile)
		if e != nil {
			return e
		}
		*token = strings.TrimSpace(string(b))
	}
	if *token == "" {
		b := make([]byte, 32)
		if _, err := rand.Read(b); err != nil {
			return err
		}
		*token = hex.EncodeToString(b)
	}
	if *generate && (*cert != "" || *key != "") {
		return errors.New("choose generate-tls or existing TLS files")
	}
	c := config{Bind: *bind, Port: *port, Token: *token, Interval: *interval, TLSCert: *cert, TLSKey: *key, AllowHTTP: *allowHTTP}
	// Validate before changing files; placeholders satisfy the TLS pair check.
	if *generate {
		c.TLSCert = "pending"
		c.TLSKey = "pending"
	}
	if err := c.validate(); err != nil {
		return err
	}
	// Never replace ACLs on an unrelated folder selected by --config.
	entries, err := os.ReadDir(filepath.Dir(*path))
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() || (entry.Name() != filepath.Base(*path) && entry.Name() != "server.crt" && entry.Name() != "server.key") {
			return errors.New("config must be in a dedicated directory containing only config and TLS files")
		}
	}
	if err := protectDirectory(filepath.Dir(*path)); err != nil {
		return err
	}
	if *generate {
		c.TLSCert, c.TLSKey, err = generateTLS(filepath.Dir(*path), c.Bind)
		if err != nil {
			return err
		}
	} else {
		for _, p := range []*string{&c.TLSCert, &c.TLSKey} {
			if *p != "" {
				*p, err = filepath.Abs(*p)
				if err != nil {
					return err
				}
			}
		}
	}
	if c.TLSCert != "" {
		if _, err := tls.LoadX509KeyPair(c.TLSCert, c.TLSKey); err != nil {
			return err
		}
	}
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	if err := writePrivate(*path, append(b, '\n')); err != nil {
		return err
	}
	fmt.Println("Saved configuration:", *path)
	fmt.Println("Run hyperv-monitor.exe with no arguments to start; use --config for a custom path.")
	if c.TLSCert != "" {
		fmt.Println("Trust this public certificate in Homarr:", c.TLSCert)
	}
	return nil
}

type limitedBuffer struct {
	data     []byte
	overflow bool
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	n := len(p)
	remaining := 4*1024*1024 - len(b.data)
	if len(p) > remaining {
		p = p[:remaining]
		b.overflow = true
	}
	b.data = append(b.data, p...)
	return n, nil
}

func collect(ctx context.Context) ([]byte, error) {
	cmd := powershell(ctx, collector)
	var output limitedBuffer
	cmd.Stdout = &output
	// Do not send raw PowerShell errors or host data to unauthenticated clients.
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("Hyper-V collection failed: %w (check Hyper-V permissions and counters)", err)
	}
	if output.overflow {
		return nil, errors.New("snapshot exceeds 4 MiB")
	}
	var payload struct {
		SchemaVersion int               `json:"schemaVersion"`
		CollectedAt   time.Time         `json:"collectedAt"`
		Host          json.RawMessage   `json:"host"`
		VMs           []json.RawMessage `json:"virtualMachines"`
	}
	if err := json.Unmarshal(output.data, &payload); err != nil {
		return nil, errors.New("invalid collector JSON")
	}
	if payload.SchemaVersion != 1 || len(payload.Host) == 0 || payload.VMs == nil || time.Since(payload.CollectedAt) > time.Minute || time.Until(payload.CollectedAt) > time.Minute {
		return nil, errors.New("invalid or stale collector snapshot")
	}
	return output.data, nil
}

type snapshotCache struct {
	sync.RWMutex
	data    []byte
	sampled time.Time
}

func (s *snapshotCache) set(data []byte) {
	s.Lock()
	defer s.Unlock()
	s.data = data
	s.sampled = time.Now()
}
func (s *snapshotCache) sample(ctx context.Context, interval time.Duration) {
	for {
		child, cancel := context.WithTimeout(ctx, 30*time.Second)
		data, err := collect(child)
		cancel()
		if err != nil {
			s.set(nil)
			if ctx.Err() == nil {
				log.Print(err)
			}
		} else {
			s.set(data)
		}
		timer := time.NewTimer(interval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}

func handler(c config, s *snapshotCache) http.Handler {
	expected := sha256.Sum256([]byte("Bearer " + c.Token))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		fail := func(code int, message string) { w.WriteHeader(code); fmt.Fprintf(w, `{"error":%q}`, message) }
		actual := sha256.Sum256([]byte(r.Header.Get("Authorization")))
		if subtle.ConstantTimeCompare(expected[:], actual[:]) != 1 {
			w.Header().Set("WWW-Authenticate", "Bearer")
			fail(401, "unauthorized")
			return
		}
		if r.URL.Path != "/api/v1/snapshot" {
			fail(404, "not_found")
			return
		}
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", "GET")
			fail(405, "method_not_allowed")
			return
		}
		s.RLock()
		data, age := s.data, time.Since(s.sampled)
		s.RUnlock()
		if len(data) == 0 || age > time.Minute {
			w.Header().Set("Retry-After", fmt.Sprint(c.Interval))
			fail(503, "metrics_unavailable")
			return
		}
		w.Write(data)
	})
}

func run(args []string) error {
	f := flag.NewFlagSet("run", flag.ContinueOnError)
	path := f.String("config", defaultPath(), "configuration file")
	if err := f.Parse(args); err != nil {
		return err
	}
	if f.NArg() != 0 {
		return errors.New("unexpected run arguments")
	}
	c, err := loadConfig(*path)
	if err != nil {
		return fmt.Errorf("load config (first run: hyperv-monitor.exe configure): %w", err)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()
	s := &snapshotCache{}
	server := &http.Server{Addr: net.JoinHostPort(c.Bind, fmt.Sprint(c.Port)), Handler: handler(c, s), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8192, TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12}}
	listener, err := net.Listen("tcp", server.Addr)
	if err != nil {
		return err
	}
	defer listener.Close()
	if c.TLSCert != "" {
		cert, err := tls.LoadX509KeyPair(c.TLSCert, c.TLSKey)
		if err != nil {
			return err
		}
		server.TLSConfig.Certificates = []tls.Certificate{cert}
		listener = tls.NewListener(listener, server.TLSConfig)
	}
	go s.sample(ctx, time.Duration(c.Interval)*time.Second)
	go func() {
		<-ctx.Done()
		shutdown, c := context.WithTimeout(context.Background(), 5*time.Second)
		defer c()
		server.Shutdown(shutdown)
	}()
	scheme := "http"
	if c.TLSCert != "" {
		scheme = "https"
	}
	log.Printf("Hyper-V monitor %s listening on %s://%s (read-only)", version, scheme, server.Addr)
	err = server.Serve(listener)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func main() {
	var err error
	args := os.Args[1:]
	if len(args) > 0 {
		switch args[0] {
		case "configure":
			err = configure(args[1:])
		case "version":
			fmt.Println(version)
			return
		case "run":
			err = run(args[1:])
		case "help", "--help", "-h":
			fmt.Println("hyperv-monitor.exe configure [--bind IP --port PORT --token TOKEN --generate-tls]\nhyperv-monitor.exe [run] [--config PATH]\nConfiguration defaults to ~/.homarr-hyperv-monitor/config.json. Use configure --help for all options.")
			return
		default:
			err = run(args)
		}
	} else {
		err = run(nil)
	}
	if err != nil {
		log.Print(err)
		os.Exit(1)
	}
}
