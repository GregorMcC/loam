package session_test

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// runSettingsFile is the part of the settings file of a run that names the
// Loam home.
type runSettingsFile struct {
	Env   map[string]string `json:"env"`
	Hooks map[string][]struct {
		Hooks []struct {
			Command string `json:"command"`
		} `json:"hooks"`
	} `json:"hooks"`
}

func readRunSettings(t *testing.T, plan *session.Plan) runSettingsFile {
	t.Helper()
	files := argValues(plan.Args, "--settings")
	if len(files) != 1 {
		t.Fatalf("args %v have no one --settings", plan.Args)
	}
	data, err := os.ReadFile(files[0])
	if err != nil {
		t.Fatal(err)
	}
	var got runSettingsFile
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	return got
}

// TAS-208: the Claude Code supervisor keeps the environment of the first
// claude --bg call, so a run session can inherit another LOAM_HOME and the
// socket of a pane. The settings of a run name the home of its store in each
// hook command and in env, and set LOAM_PANE_SOCKET to empty.
func TestPrepareRunNamesTheHomeOfTheStore(t *testing.T) {
	e := setup(t)
	repo, _ := testutil.GitRepo(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: repo}}})
	plan, err := session.PrepareRun(e.store, store.Run{ID: "r1", PlotID: p.ID, Folder: repo}, "go", "/bin/lo am", "", "")
	if err != nil {
		t.Fatal(err)
	}
	got := readRunSettings(t, plan)
	home := e.store.Home()
	want := "LOAM_HOME='" + home + "' '/bin/lo am' run hook r1"
	for _, ev := range []string{"SessionStart", "Stop", "StopFailure"} {
		h := got.Hooks[ev]
		if len(h) != 1 || len(h[0].Hooks) != 1 || h[0].Hooks[0].Command != want {
			t.Errorf("%s hook %+v, want the command %q", ev, h, want)
		}
	}
	if got.Env["LOAM_HOME"] != home {
		t.Errorf("env LOAM_HOME = %q, want %q", got.Env["LOAM_HOME"], home)
	}
	if v, ok := got.Env["LOAM_PANE_SOCKET"]; !ok || v != "" {
		t.Errorf("env LOAM_PANE_SOCKET = %q (set %v), want it set and empty", v, ok)
	}
}

// TAS-208: a hook that runs with LOAM_HOME set to another folder still
// records the session in the store of the run.
func TestRunHookRecordsTheSessionInTheStoreOfTheRun(t *testing.T) {
	e := setup(t)
	repo, _ := testutil.GitRepo(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: repo}}})
	r, err := e.store.AddRun(store.Run{PlotID: p.ID, Folder: repo, Title: "Fix the thing"})
	if err != nil {
		t.Fatal(err)
	}
	plan, err := session.PrepareRun(e.store, r, "go", e.bin, "", "")
	if err != nil {
		t.Fatal(err)
	}
	hooks := readRunSettings(t, plan).Hooks["SessionStart"]
	if len(hooks) != 1 || len(hooks[0].Hooks) != 1 {
		t.Fatalf("SessionStart hooks %+v", hooks)
	}

	other := filepath.Join(t.TempDir(), "other-home")
	const id = "c57ef956-3136-4e86-bfde-da8facfe0523"
	cmd := exec.Command("/bin/sh", "-c", hooks[0].Hooks[0].Command)
	cmd.Dir = repo
	cmd.Env = append(os.Environ(), "LOAM_HOME="+other)
	cmd.Stdin = strings.NewReader(`{"hook_event_name":"SessionStart","session_id":"` + id + `","source":"startup","cwd":"` + repo + `"}`)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, out)
	}

	got, err := e.store.GetRun(r.ID)
	if err != nil || got.SessionID != id {
		t.Fatalf("run %+v %v, want session %s", got, err, id)
	}
	if _, err := os.Stat(other); !os.IsNotExist(err) {
		t.Errorf("the hook used the LOAM_HOME of its environment: %v", err)
	}
}
