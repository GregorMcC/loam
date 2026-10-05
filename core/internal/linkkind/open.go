package linkkind

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// How a link was opened.
const (
	ViaBrowser    = "browser"     // a URL, in the default browser
	ViaObsidian   = "obsidian"    // a vault file, in Obsidian
	ViaFinder     = "finder"      // a folder, or a file that is revealed and not run
	ViaDefaultApp = "default_app" // a file, in its default app
)

// ErrMissing means a local path does not exist.
var ErrMissing = errors.New("path does not exist")

// ErrNotURL means a target is not a local path and has no URL scheme.
var ErrNotURL = errors.New("not a URL")

// ErrScheme means a URL has a scheme that Loam does not open.
var ErrScheme = errors.New("URL scheme is not allowed")

// allowedSchemes are the URL schemes that Open hands to the open command. A
// link can come from a Claude session, and open runs the handler of any
// scheme, so the list stays short: the web, mail, and the apps that plots
// link to.
var allowedSchemes = map[string]bool{
	"http": true, "https": true, "mailto": true,
	"obsidian": true, "notion": true, "linear": true, "slack": true,
}

// runsWhenOpened are the file extensions that the open command runs instead
// of showing, in lower case with the dot.
var runsWhenOpened = map[string]bool{
	".app": true, ".command": true, ".tool": true, ".terminal": true,
	".pkg": true, ".mpkg": true, ".workflow": true, ".action": true, ".jar": true,
}

// openBin is the macOS open command. LOAM_OPEN replaces it. It is the one seam
// that tests use to fake every open.
func openBin() string {
	if p := os.Getenv("LOAM_OPEN"); p != "" {
		return p
	}
	return "/usr/bin/open"
}

func runOpen(args ...string) error {
	out, err := exec.Command(openBin(), args...).CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = err.Error()
		}
		return fmt.Errorf("open %s: %s", strings.Join(args, " "), msg)
	}
	return nil
}

// Open opens a link with the macOS open command and returns how it opened
// it. An http or https URL opens in the default browser, and a URL with
// another allowed scheme in the app that handles it. A URL with any other
// scheme gives [ErrScheme], and nothing runs. A vault file opens in Obsidian,
// or in its default app when open cannot open the obsidian:// link. A folder
// opens in Finder. Any other file opens in its default app. A file or a bundle
// that open would run, such as an executable, a .command file, or an .app, is
// revealed in Finder instead. A local path that does not exist gives
// [ErrMissing], and nothing runs.
func Open(info Info) (via string, err error) {
	if !info.Local {
		u, perr := url.Parse(info.Target)
		if perr != nil || u.Scheme == "" {
			return "", fmt.Errorf("%q is %w or an absolute path", info.Target, ErrNotURL)
		}
		scheme := strings.ToLower(u.Scheme)
		if !allowedSchemes[scheme] {
			return "", fmt.Errorf("%q: the %s %w", info.Target, scheme, ErrScheme)
		}
		via := ViaDefaultApp
		if scheme == "http" || scheme == "https" {
			via = ViaBrowser
		}
		return done(via, runOpen(info.Target))
	}
	if !info.Exists {
		return "", ErrMissing
	}
	if runs(info.Path) {
		return done(ViaFinder, runOpen("-R", info.Path))
	}
	if info.IsDir {
		return done(ViaFinder, runOpen(info.Path))
	}
	// open fails when no app handles obsidian://, so a failure means no Obsidian.
	if info.Kind == Vault && runOpen(obsidianURI(info.Path)) == nil {
		return ViaObsidian, nil
	}
	return done(ViaDefaultApp, runOpen(info.Path))
}

// runs reports whether the open command would run the path instead of
// showing it: a regular file with an execute bit, a file or folder with an
// extension in runsWhenOpened, or a bundle folder (one with
// Contents/Info.plist). A path that cannot be read counts as one that runs.
func runs(path string) bool {
	fi, err := os.Stat(path)
	if err != nil {
		return true
	}
	if runsWhenOpened[strings.ToLower(filepath.Ext(path))] {
		return true
	}
	if fi.IsDir() {
		_, err := os.Stat(filepath.Join(path, "Contents", "Info.plist"))
		return err == nil
	}
	return fi.Mode().Perm()&0o111 != 0
}

// done returns via when err is nil, else no via.
func done(via string, err error) (string, error) {
	if err != nil {
		return "", err
	}
	return via, nil
}

// obsidianURI returns the obsidian://open link for an absolute path. Obsidian
// reads %20 for a space, not +.
func obsidianURI(path string) string {
	return "obsidian://open?path=" + strings.ReplaceAll(url.QueryEscape(path), "+", "%20")
}
