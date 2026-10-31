package sandbox

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

// alwaysWrite are the folders outside home that a check can write: the
// shared temp folder and the devices, such as /dev/null and /dev/tty.
var alwaysWrite = []string{sharedTemp, "/dev"}

// loopback lets a check run a server on this Mac and reach it, as the test
// servers of Go's httptest do. A check can then reach any TCP service on
// localhost. Seatbelt checks a bind as an inbound operation, and a rule on
// localhost also matches a bind to 0.0.0.0 or ::. So a host on the network
// can connect to a server that a check starts. A check cannot connect out to
// another host: a rule on the remote address does not match it.
const loopback = `(allow network-inbound (local ip "localhost:*"))
(allow network-outbound (remote ip "localhost:*"))
`

// others denies the ways that a check can make another process act for it,
// outside the sandbox: Launch Services opens an app or a script, Apple
// Events drive an app, the security services read the keychain, and a
// signal can stop a process of the user.
const others = `(deny lsopen)
(deny appleevent-send)
(deny mach-lookup
  (global-name "com.apple.coreservices.launchservicesd")
  (global-name "com.apple.coreservices.appleevents")
  (global-name "com.apple.CoreServices.coreservicesd")
  (global-name "com.apple.SecurityServer")
  (global-name "com.apple.securityd.xpc"))
(deny signal)
(allow signal (target same-sandbox))
`

// Profile returns the rules as a Seatbelt profile for sandbox-exec, which
// the gate runs each check with. temps are the temp folders of the gate, from
// [Temps], which the checks can read and write. In a profile, the last rule
// that matches an operation wins. So the profile denies home and then allows
// the Read paths and the temp folders, denies every write and then allows
// the Write paths, the temp folders, and alwaysWrite, and denies each
// DenyWrite path and the xcrun cache of each temp folder last.
//
// The profile denies the ways out through other processes (see others). It
// denies the network, so a check uses the caches that the session filled,
// and Hosts do not apply. It allows loopback, and the unix
// sockets below the Write paths and the temp folders. Other sockets, such as
// the SSH agent and the Docker socket, can act as the user. It returns an
// error when the home folder is not absolute, because the profile would then
// deny nothing, and when the profile is longer than MaxProfile.
func (r Rules) Profile(temps ...string) (string, error) {
	if !filepath.IsAbs(r.Home) {
		return "", errors.New("the sandbox profile needs the home folder, and it is not set")
	}
	var b strings.Builder
	b.WriteString("(version 1)\n(allow default)\n")
	b.WriteString(others)
	b.WriteString("(deny network*)\n")
	b.WriteString(loopback)
	// Seatbelt matches the real path of a socket, so a link to a socket
	// elsewhere does not open it.
	rule(&b, "allow", "network*", append(append([]string(nil), r.Write...), r.socketTemps(temps)...),
		"(local unix-socket (subpath %s))", "(remote unix-socket (subpath %s))")
	rule(&b, "deny", "file-read*", []string{r.Home}, subpath)
	rule(&b, "allow", "file-read*", append(append([]string(nil), r.Read...), r.temps(temps)...), subpath)
	// Metadata gives names and sizes, not the content of a file. Git reads
	// the metadata of each folder above the repo.
	b.WriteString("(allow file-read-metadata)\n")
	b.WriteString("(deny file-write*)\n")
	rule(&b, "allow", "file-write*", r.writes(temps), subpath)
	rule(&b, "deny", "file-write*", r.DenyWrite, subpath)
	rule(&b, "deny", "file-write*", r.xcrunCaches(temps), "(literal %s)")
	if b.Len() > MaxProfile {
		return "", fmt.Errorf("the sandbox profile is %d bytes, more than the %d bytes that Loam passes to sandbox-exec: the rules name too many paths", b.Len(), MaxProfile)
	}
	return b.String(), nil
}

// xcrunCache is the file in the temp folder of the user where the xcrun
// shims, such as /usr/bin/git, keep the path of each tool. They run that path
// with no check. A check that wrote the file would make the next git outside
// the sandbox, of Loam or of the user, run a file of the check.
const xcrunCache = "xcrun_db"

// xcrunCaches returns xcrunCache in each temp folder. The deny also stops a
// hard link to the file, and a rename of a file onto it or of it away.
func (r Rules) xcrunCaches(temps []string) []string {
	var out []string
	for _, t := range r.temps(temps) {
		out = append(out, filepath.Join(t, xcrunCache))
	}
	return out
}

// writes returns the Write paths, the temp folders, and alwaysWrite.
func (r Rules) writes(temps []string) []string {
	out := append(append([]string(nil), r.Write...), r.temps(temps)...)
	return append(out, alwaysWrite...)
}

// temps returns the temp folders by their real paths. It leaves out a folder
// that would open home.
func (r Rules) temps(temps []string) []string {
	var out []string
	for _, t := range temps {
		if t = Real(t); t != "" && !opens(r.Home, t) {
			out = append(out, t)
		}
	}
	return out
}

// MaxProfile is the longest profile, in bytes, that Loam passes to
// sandbox-exec. Loam passes it as an argument, and macOS limits the
// arguments and the environment of a process together to 1 MiB (ARG_MAX).
const MaxProfile = 256 << 10

// sharedTemp holds the socket of the launchd SSH agent, so no unix socket in
// it is allowed.
const sharedTemp = "/private/tmp"

// socketTemps returns the temp folders that can hold the unix sockets of a
// check: each one but a folder that holds sharedTemp, as a TMPDIR of /tmp, or
// that holds the temp or the cache folder of the user. Other processes of the
// user keep their sockets there, such as the pane sockets of Loam, and the
// diagnostics socket of a .NET process, which can load code into it.
func (r Rules) socketTemps(temps []string) []string {
	shared := append([]string{sharedTemp}, userFolders()...)
	var out []string
	for _, t := range r.temps(temps) {
		if !slices.ContainsFunc(shared, func(s string) bool { return within(s, t) }) {
			out = append(out, t)
		}
	}
	return out
}

// userFolders returns the temp and the cache folder of the user by their
// real paths.
var userFolders = func() []string {
	var out []string
	for _, name := range []string{"DARWIN_USER_TEMP_DIR", "DARWIN_USER_CACHE_DIR"} {
		if d := getconf(name); d != "" {
			out = append(out, Real(d))
		}
	}
	return out
}

// Temps returns the temp folders of this process that a check can write:
// TMPDIR when it is an absolute path, and the temp and cache folders of the
// user that macOS names. The xcrun shims, such as /usr/bin/python3, keep a
// cache in the temp folder of the user, which can differ from TMPDIR. clang
// and swift keep their module caches in the cache folder. It leaves out a
// folder that getconf cannot name, and a folder that it already has.
func Temps() []string {
	var out []string
	if t := os.Getenv("TMPDIR"); filepath.IsAbs(t) {
		out = append(out, t)
	}
	for _, name := range []string{"DARWIN_USER_TEMP_DIR", "DARWIN_USER_CACHE_DIR"} {
		if p := getconf(name); p != "" && !slices.ContainsFunc(out, func(o string) bool { return Real(o) == Real(p) }) {
			out = append(out, p)
		}
	}
	return out
}

// XcrunCache returns the cache of the xcrun shims of this user: xcrunCache in
// the temp folder of the user. It returns "" when getconf cannot name the
// folder.
func XcrunCache() string {
	if d := getconf("DARWIN_USER_TEMP_DIR"); d != "" {
		return filepath.Join(d, xcrunCache)
	}
	return ""
}

// getconf returns the folder that getconf names, or "" when it names no
// absolute path.
func getconf(name string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	b, err := exec.CommandContext(ctx, "/usr/bin/getconf", name).Output()
	if p := strings.TrimSpace(string(b)); err == nil && filepath.IsAbs(p) {
		return p
	}
	return ""
}

// subpath is the filter of a path and the paths inside it.
const subpath = "(subpath %s)"

// rule writes one rule with each filter for each path. A filter has %s for
// the quoted path. It writes nothing for no paths: a rule with no filter
// matches everything.
func rule(b *strings.Builder, action, op string, paths []string, filters ...string) {
	if len(paths) == 0 {
		return
	}
	fmt.Fprintf(b, "(%s %s", action, op)
	for _, p := range paths {
		for _, f := range filters {
			fmt.Fprintf(b, "\n  "+f, quote(p))
		}
	}
	b.WriteString(")\n")
}

// quote returns s as an SBPL string literal. It escapes the quote, the
// backslash, and each control character, so that no path can end the
// literal or change the profile.
func quote(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case c == '"' || c == '\\':
			b.WriteByte('\\')
			b.WriteByte(c)
		case c == '\n':
			b.WriteString(`\n`)
		case c == '\r':
			b.WriteString(`\r`)
		case c == '\t':
			b.WriteString(`\t`)
		case c < 0x20 || c == 0x7f:
			fmt.Fprintf(&b, `\x%02x`, c)
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}
