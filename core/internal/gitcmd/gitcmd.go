// Package gitcmd builds the git commands that Loam runs outside the sandbox.
//
// A run can write the git folder of its repo. Git follows a commondir file in
// that folder, or in the metadata folder of a worktree, and takes the config and
// the hooks of the folder that the file names. So config that a run wrote would
// reach git outside the sandbox, and git would run a command that the config
// names, such as core.fsmonitor or core.sshCommand. A check cannot close this,
// because the run can write the file after the check. So each git command of
// Loam sets GIT_COMMON_DIR to the git folder of the repo, and git then does not
// take the config or the hooks that the file names.
//
// Git still reads the refs of a worktree through the file. So the file can
// change which commit Loam reads for a branch, as the run can with no such file.
// It cannot change the config.
package gitcmd

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
)

// Command returns git with args in dir. Its Env is set, so a caller appends to
// it.
func Command(ctx context.Context, dir string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...)
	cmd.Env = Env(dir)
	return cmd
}

// NoRepoDir is a GIT_DIR that can name no repo, because /dev/null is not a
// folder.
const NoRepoDir = "/dev/null/loam-no-repo"

// NoRepoEnv returns the environment of this process with GIT_DIR set to
// [NoRepoDir]. Each git command in that environment fails, as outside a repo. It
// reads only the system and global config, and it starts no git in a nested
// repo.
//
// Use it for a program that Loam starts outside the sandbox in a folder that a
// run can write, that does not need git, and whose git commands Loam does not
// choose, such as claude -p with tools that only read. [Env] is not enough there.
// Git clears GIT_COMMON_DIR for the git that it starts in a nested repo, and only
// a flag on the git command stops that start: config in .gitmodules, which the
// run can write, undoes -c diff.ignoreSubmodules=all.
func NoRepoEnv() []string {
	return append(ownEnv(), "GIT_DIR="+NoRepoDir)
}

// Env returns the environment of this process with GIT_COMMON_DIR set to the
// git folder of the repo that holds dir, and with no other variable that chooses
// a repo (see [ownEnv]). It sets no value when dir is in no repo, or when the
// .git file of dir does not name a worktree.
//
// Git clears this setting for the git that it starts in a nested repo, which a
// run can make. So a git command that can start one, such as status, diff with
// the work tree, a switch that prints local changes, or fetch, must also say not
// to: see [NoRepoEnv].
func Env(dir string) []string {
	env := ownEnv()
	if common := CommonDir(dir); common != "" {
		env = append(env, "GIT_COMMON_DIR="+common)
	}
	return env
}

// ownEnv returns the environment of this process with no variable that chooses
// a repo or a part of it. Loam inherits these from a git hook that starts it.
// Each command here names its folder, and -C does not override GIT_DIR. An
// inherited GIT_DIR can also name the metadata folder of a worktree of a run, and
// git then follows the commondir file in it. The config variables stay: they do
// not come from a file that a run can write.
func ownEnv() []string {
	return slices.DeleteFunc(os.Environ(), func(kv string) bool {
		k, _, _ := strings.Cut(kv, "=")
		switch k {
		case "GIT_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
			"GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_GRAFT_FILE", "GIT_SHALLOW_FILE", "GIT_PREFIX":
			return true
		}
		return false
	})
}

// CommonDir returns the git folder that the worktree or the repo that holds dir
// shares, or "". It finds the .git of dir as git does, from dir up. It does not
// ask git, and it reads no file in the git folder, because the run can write
// them. The run cannot write the .git file of a worktree, or move a folder above
// it or above the .git folder of a repo.
func CommonDir(dir string) string {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return ""
	}
	for {
		dotgit := filepath.Join(abs, ".git")
		if fi, err := os.Stat(dotgit); err == nil {
			if fi.IsDir() {
				return dotgit
			}
			return fromFile(abs, dotgit)
		}
		parent := filepath.Dir(abs)
		if parent == abs {
			return ""
		}
		abs = parent
	}
}

// fromFile returns the git folder of the worktree in folder from its .git file,
// which names <git folder>/worktrees/<name>. It returns "" for any other value,
// such as the git folder of a submodule. It takes the folder by the text, so a
// link that the run puts in place of the worktrees folder does not move it.
func fromFile(folder, dotgit string) string {
	b, err := os.ReadFile(dotgit)
	if err != nil {
		return ""
	}
	admin, ok := strings.CutPrefix(strings.TrimSpace(string(b)), "gitdir: ")
	if !ok {
		return ""
	}
	if !filepath.IsAbs(admin) {
		admin = filepath.Join(folder, admin)
	}
	parent := filepath.Dir(filepath.Clean(admin))
	if filepath.Base(parent) != "worktrees" {
		return ""
	}
	return filepath.Dir(parent)
}
