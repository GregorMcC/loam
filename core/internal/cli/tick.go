package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/GregorMcC/loam/core/internal/run"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/spf13/cobra"
)

func init() {
	Register(newTickCmd)
}

// tickLabel is the launchd label of the agent that runs loam tick.
const tickLabel = "dev.loam.tick"

// tickInterval is how often launchd runs loam tick, in seconds.
const tickInterval = 300

// tickResult is the output of loam tick.
type tickResult struct {
	Recurring []run.RecurringResult `json:"recurring"`
	Runs      []store.Run           `json:"runs"`
	Warnings  []string              `json:"warnings"`
}

// lastTick is what the last loam tick did, for loam tick status.
type lastTick struct {
	At    time.Time `json:"at"`
	Error string    `json:"error"`
}

// tickStatus is the output of loam tick status, install, and uninstall.
type tickStatus struct {
	// Installed is true when the launchd agent runs loam tick.
	Installed bool   `json:"installed"`
	Plist     string `json:"plist"`
	// Interval is how often the agent runs loam tick, in seconds.
	Interval int       `json:"interval"`
	LastTick *lastTick `json:"last_tick,omitempty"`
}

func newTickCmd() *cobra.Command {
	var now string
	c := &cobra.Command{
		Use:   "tick",
		Short: "Start the recurring runs that are due, and ship the runs whose checks passed",
		Long: "Start each recurring run that is due, then do what loam run tick does: push, open the PR, and read CI.\n" +
			"A tick that has nothing to do changes nothing, so it is safe to run often. loam tick install has launchd run it every 5 minutes, so runs move on when the app is closed.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			at := time.Now()
			if now != "" {
				if at, err = time.Parse(time.RFC3339, now); err != nil {
					return fmt.Errorf("--now %q: %v: %w", now, err, store.ErrInvalid)
				}
			}
			res, err := tickAll(cmd, s, at)
			writeLastTick(s.Home(), at, err)
			if err != nil {
				return err
			}
			printWarnings(cmd, res.Warnings)
			if JSON(cmd) {
				return printJSON(cmd, res)
			}
			for _, r := range res.Recurring {
				printRecurringResult(cmd.OutOrStdout(), r)
			}
			for _, r := range res.Runs {
				printRun(cmd.OutOrStdout(), r)
			}
			return nil
		},
	}
	c.Flags().StringVar(&now, "now", "", "the time of the tick, in RFC 3339 (for tests)")
	c.Flags().MarkHidden("now")
	c.AddCommand(newTickInstallCmd(), newTickUninstallCmd(), newTickStatusCmd())
	return c
}

func tickAll(cmd *cobra.Command, s *store.Store, now time.Time) (tickResult, error) {
	loam, err := loamBinary()
	if err != nil {
		return tickResult{}, err
	}
	recurring, err := run.TickRecurring(cmd.Context(), s, now, loam)
	if err != nil {
		return tickResult{}, err
	}
	shipped, err := run.Tick(cmd.Context(), s, loam)
	if err != nil {
		return tickResult{}, err
	}
	return tickResult{Recurring: recurring, Runs: shipped.Runs, Warnings: shipped.Warnings}, nil
}

func writeLastTick(home string, at time.Time, err error) {
	last := lastTick{At: at}
	if err != nil {
		last.Error = err.Error()
	}
	if b, err := json.Marshal(last); err == nil {
		_ = os.WriteFile(filepath.Join(home, "last-tick.json"), b, 0o600)
	}
}

func newTickInstallCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "install",
		Short: "Have launchd run loam tick every 5 minutes, while you are logged in",
		Long: "Write a launchd agent that runs this loam binary with tick every 5 minutes, and load it. The agent keeps the PATH and LOAM_HOME of this command, so the runs find claude, git, and gh.\n" +
			"Install again after you move the loam binary.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			loam, err := loamBinary()
			if err != nil {
				return err
			}
			plist, err := tickPlist()
			if err != nil {
				return err
			}
			if err := os.MkdirAll(filepath.Dir(plist), 0o755); err != nil {
				return err
			}
			env := map[string]string{"PATH": os.Getenv("PATH")}
			if h := os.Getenv("LOAM_HOME"); h != "" {
				env["LOAM_HOME"] = h
			}
			if err := os.WriteFile(plist, []byte(plistText(loam, env)), 0o644); err != nil {
				return err
			}
			// A loaded agent keeps its old plist until launchd loads it again.
			_ = launchctl("bootout", launchDomain()+"/"+tickLabel)
			if err := launchctl("bootstrap", launchDomain(), plist); err != nil {
				return fmt.Errorf("launchd did not load %s: %w", plist, err)
			}
			return printTickStatus(cmd, s.Home())
		},
	}
}

func newTickUninstallCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "uninstall",
		Short: "Stop launchd from running loam tick",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			plist, err := tickPlist()
			if err != nil {
				return err
			}
			_ = launchctl("bootout", launchDomain()+"/"+tickLabel)
			if err := os.Remove(plist); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
			return printTickStatus(cmd, s.Home())
		},
	}
}

func newTickStatusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Say whether launchd runs loam tick, and when the last tick was",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			return printTickStatus(cmd, s.Home())
		},
	}
}

func printTickStatus(cmd *cobra.Command, home string) error {
	plist, err := tickPlist()
	if err != nil {
		return err
	}
	st := tickStatus{Plist: plist, Interval: tickInterval}
	_, err = os.Stat(plist)
	st.Installed = err == nil
	if b, err := os.ReadFile(filepath.Join(home, "last-tick.json")); err == nil {
		var last lastTick
		if json.Unmarshal(b, &last) == nil {
			st.LastTick = &last
		}
	}
	if JSON(cmd) {
		return printJSON(cmd, st)
	}
	out := cmd.OutOrStdout()
	if st.Installed {
		fmt.Fprintf(out, "launchd runs loam tick every %d minutes (%s)\n", tickInterval/60, plist)
	} else {
		fmt.Fprintln(out, "launchd does not run loam tick. loam tick install sets it up")
	}
	if st.LastTick != nil {
		fmt.Fprintf(out, "Last tick: %s\n", st.LastTick.At.Format("Mon 2 Jan 15:04"))
		if st.LastTick.Error != "" {
			fmt.Fprintf(out, "It failed: %s\n", oneLine(st.LastTick.Error))
		}
	}
	return nil
}

func tickPlist() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "LaunchAgents", tickLabel+".plist"), nil
}

func launchDomain() string { return "gui/" + strconv.Itoa(os.Getuid()) }

// launchctl runs launchctl, or the program that LOAM_LAUNCHCTL names (for
// tests).
func launchctl(args ...string) error {
	bin := os.Getenv("LOAM_LAUNCHCTL")
	if bin == "" {
		bin = "/bin/launchctl"
	}
	out, err := exec.Command(bin, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// plistText is the launchd agent that runs loam tick every tickInterval
// seconds, with env. launchd drops its output: each tick records what it did
// in the store and in last-tick.json.
func plistText(loam string, env map[string]string) string {
	var b strings.Builder
	b.WriteString(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>` + tickLabel + `</string>
  <key>ProgramArguments</key>
  <array><string>` + html.EscapeString(loam) + `</string><string>tick</string></array>
  <key>StartInterval</key><integer>` + strconv.Itoa(tickInterval) + `</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
  <key>EnvironmentVariables</key>
  <dict>
`)
	for _, k := range []string{"PATH", "LOAM_HOME"} {
		if v, ok := env[k]; ok {
			b.WriteString("    <key>" + k + "</key><string>" + html.EscapeString(v) + "</string>\n")
		}
	}
	b.WriteString("  </dict>\n</dict>\n</plist>\n")
	return b.String()
}
