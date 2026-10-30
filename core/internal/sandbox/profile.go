package sandbox

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// alwaysWrite are the folders outside home that a check can write: the
// shared temp folder and the devices, such as /dev/null and /dev/tty.
var alwaysWrite = []string{"/private/tmp", "/dev"}

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
// DenyWrite path last.
//
// The profile denies the ways out through other processes (see others). It
// denies the network, so a check uses the caches that the session filled,
// and Hosts do not apply. It allows loopback, and the unix
// sockets below the Write paths and the temp folders. Other sockets, such as
// the SSH agent and the Docker socket, can act as the user. It returns an
// error when the home folder is not absolute, because the profile would then
// deny nothing.
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
	rule(&b, "allow", "network*", append(append([]string(nil), r.Write...), r.temps(temps)...),
		"(local unix-socket (subpath %s))", "(remote unix-socket (subpath %s))")
	rule(&b, "deny", "file-read*", []string{r.Home}, subpath)
	rule(&b, "allow", "file-read*", append(append([]string(nil), r.Read...), r.temps(temps)...), subpath)
	// Metadata gives names and sizes, not the content of a file. Git reads
	// the metadata of each folder above the repo.
	b.WriteString("(allow file-read-metadata)\n")
	b.WriteString("(deny file-write*)\n")
	rule(&b, "allow", "file-write*", r.writes(temps), subpath)
	rule(&b, "deny", "file-write*", r.DenyWrite, subpath)
	return b.String(), nil
}

// Writable reports whether a check can write path, or a folder above it, under
// the profile of [Rules.Profile]. A check that can write a folder above a
// file can move the folder and put another file in its place, so Writable
// does not take DenyWrite into account. The gate keeps its profile file out
// of these paths, so that no check can change the profile of the next one.
// It ignores case, because macOS folders are not case sensitive by default.
func (r Rules) Writable(path string, temps ...string) bool {
	path = strings.ToLower(Real(path))
	for _, w := range r.writes(temps) {
		if within(path, strings.ToLower(w)) {
			return true
		}
	}
	return false
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

// Temps returns the temp folders of this process that a check can write: the
// temp folder, and the cache folder of the user, where clang and swift keep
// their module caches. It leaves out the cache folder when getconf cannot
// name it.
func Temps() []string {
	out := []string{os.TempDir()}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	b, err := exec.CommandContext(ctx, "/usr/bin/getconf", "DARWIN_USER_CACHE_DIR").Output()
	if p := strings.TrimSpace(string(b)); err == nil && filepath.IsAbs(p) {
		out = append(out, p)
	}
	return out
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
