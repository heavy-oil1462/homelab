{ config, pkgs, lib, ... }:

let
  sb = config.homelab.agentSandbox;

  # This creates the standard Linux /lib64 and /lib paths in the container.
  # Now, pre-compiled binaries downloaded from the internet will find the dynamic linker
  # and other common runtime libraries (like C++ standard library).
  #
  # This covers BOTH the Antigravity CLI binary and the Claude Code native binary,
  # since both are pre-compiled self-contained executables that expect a normal FHS layout.
  fhsCompat = pkgs.runCommand "fhs-compat" { } ''
    mkdir -p $out/lib64 $out/lib $out/usr/bin
    ln -s ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 $out/lib64/ld-linux-x86-64.so.2
    ln -s ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 $out/lib/ld-linux-x86-64.so.2

    # Map C++ standard libraries for binaries that require them
    ln -s ${pkgs.stdenv.cc.cc.lib}/lib/libstdc++.so.6 $out/lib/libstdc++.so.6
    ln -s ${pkgs.stdenv.cc.cc.lib}/lib/libgcc_s.so.1 $out/lib/libgcc_s.so.1

    # Map /usr/bin/env for standard script shebangs
    ln -s ${pkgs.coreutils}/bin/env $out/usr/bin/env
  '';

  # Runs on every container start, BEFORE the requested command (shell/agy/claude).
  # All writes go to the container's GLOBAL git config (/root/.gitconfig, which lives
  # in the persisted state volume) and to gh's own state — never to the shared
  # /workspace/.git. The host keeps its SSH remote and SSH auth untouched.
  entrypoint = pkgs.writeShellScriptBin "agent-entrypoint" ''
    set -euo pipefail

    # Make the in-container Nix store usable so 'nix flake check', 'nix build', etc.
    # work. A hand-built dockerTools image ships the store contents but not these
    # var dirs; once they exist Nix initializes its SQLite db on first use.
    mkdir -p /nix/var/nix/db /nix/var/nix/profiles /nix/var/nix/gcroots /nix/var/nix/temproots 2>/dev/null || true

    # Trust the bind-mounted repo despite the uid mismatch between host and container.
    if ! git config --global --get-all safe.directory 2>/dev/null | grep -qx /workspace; then
      git config --global --add safe.directory /workspace
    fi

    # Rewrite GitHub SSH URLs to HTTPS for THIS container only, so pushes use the
    # credential helper instead of an SSH key — without editing the repo's 'origin'
    # (which is shared with the host via /workspace/.git).
    git config --global url."https://github.com/".insteadOf "git@github.com:"

    # Authentication is left entirely to 'gh auth login' (run it once; it persists in
    # the state volume and sets gh as git's credential helper). gh auth login only
    # writes the helper into the gitconfig of the project it ran in, and gitconfigs
    # are per-project (/root is a per-project volume), so pin the helper here too:
    # auth itself is shared via the agent-secrets volume, and this makes it usable
    # from every project.
    git config --global credential."https://github.com".helper '!gh auth git-credential'

    ${lib.optionalString (sb.gitName != null && sb.gitEmail != null) ''
      # Pin the commit identity on every start, so nothing committed from inside a
      # sandbox can ever carry an unintended email or name, regardless of what the
      # per-project volume's gitconfig has accumulated.
      git config --global user.name "${sb.gitName}"
      git config --global user.email "${sb.gitEmail}"
    ''}

    ${lib.optionalString (sb.allowedEmails != [ ]) ''
      # Warn (never modify) when the mounted repo pins its own commit identity to
      # something outside the allowed set. Repo-local config in /workspace/.git
      # overrides the pinned global identity above, and /workspace is shared with
      # the host, so it is only ever inspected from here, not edited.
      effective_email=$(git -C /workspace config user.email 2>/dev/null || true)
      case "$effective_email" in
        ""|${lib.concatStringsSep "|" sb.allowedEmails}) ;;
        *)
          echo "[identity] WARNING: commits in /workspace will use '$effective_email'"
          echo "[identity] repo-local .git/config overrides the pinned identity;"
          echo "[identity] fix with: git config --unset user.email; git config --unset user.name"
          ;;
      esac
    ''}

    # Share the Claude Code login across projects. /root is per-project, so
    # without this every new project volume needs 'claude' login again. The
    # credentials file becomes a symlink into the shared volume: a login or
    # token refresh in any project lands there immediately. If claude ever
    # replaces the symlink with a plain file, the newer file is pushed back to
    # the volume on the next start and re-linked.
    mkdir -p /root/.claude
    if [ -f /root/.claude/.credentials.json ] && [ ! -L /root/.claude/.credentials.json ]; then
      if [ ! -f /root/.claude-auth/credentials.json ] || [ /root/.claude/.credentials.json -nt /root/.claude-auth/credentials.json ]; then
        cp -f /root/.claude/.credentials.json /root/.claude-auth/credentials.json
      fi
    fi
    ln -sf /root/.claude-auth/credentials.json /root/.claude/.credentials.json
    chmod 600 /root/.claude-auth/credentials.json 2>/dev/null || true

    # Seed ~/.claude.json (account and onboarding state) into new project
    # volumes so they skip the first-run wizard; refresh the seed from
    # whichever project ran most recently. Copied, not symlinked: claude
    # rewrites it via rename, and it holds per-project state that should stay
    # per-project after seeding.
    if [ -f /root/.claude.json ]; then
      if [ ! -f /root/.claude-auth/claude.json ] || [ /root/.claude.json -nt /root/.claude-auth/claude.json ]; then
        cp -f /root/.claude.json /root/.claude-auth/claude.json
      fi
    elif [ -f /root/.claude-auth/claude.json ]; then
      cp /root/.claude-auth/claude.json /root/.claude.json
    fi

    ${lib.optionalString (sb.skillsRepo != null) ''
      # Sync the shared skills repo (working-style rules and personal skills) into
      # ~/.claude so every session loads them. /root/skills is a shared volume across
      # all projects; one pull updates everyone. Offline or before gh auth login the
      # last checkout is used, so failures only warn.
      if [ -d /root/skills/.git ]; then
        git -C /root/skills pull --ff-only -q 2>/dev/null \
          || echo "[skills] pull failed (offline or not authenticated); using last checkout"
      else
        git clone -q ${sb.skillsRepo} /root/skills 2>/dev/null \
          || echo "[skills] clone failed; run 'gh auth login', then restart the sandbox"
      fi
      if [ -f /root/skills/CLAUDE.md ]; then
        mkdir -p /root/.claude/skills
        cp -f /root/skills/CLAUDE.md /root/.claude/CLAUDE.md
        # Refresh same-named skills from the repo; leave any other personal skills
        # alone. The copies are overwritten every start, so edits belong in the
        # skills repo (via PR), never in ~/.claude.
        for skill in /root/skills/skills/*/; do
          [ -d "$skill" ] || continue
          name=$(basename "$skill")
          rm -rf "/root/.claude/skills/$name"
          cp -r "$skill" "/root/.claude/skills/$name"
        done
      fi
    ''}

    if [ "$#" -eq 0 ]; then
      exec /bin/bash
    fi
    exec "$@"
  '';

  sandboxImage = pkgs.dockerTools.streamLayeredImage {
    name = "agent-sandbox";
    tag = "latest";
    contents = with pkgs; [
      bashInteractive
      coreutils
      git
      curl
      cacert
      python3
      gnutar
      gzip
      gnugrep
      gnused
      which
      gawk
      findutils
      nix
      glibc
      fhsCompat
      fzf
      gh
      entrypoint

      # Project toolchains baked into the image, for languages used across
      # several projects (per-project extras still come from nix develop or
      # nix shell inside the container). go covers pure-Go builds; if a
      # project needs cgo (a C-linked dependency such as mattn/go-sqlite3),
      # add gcc here too. nodejs bundles npm, so JS/TS projects work without a
      # per-project nix shell; the global npm prefix lands under /root, so it
      # persists in the per-project state volume.
      go
      nodejs

      # Claude Code itself uses the native installer and needs no Node.js; the
      # nodejs above is baked in for project use, not for the agent install.

      # ---------------------------------------------------------------------------
      # Installers
      # ---------------------------------------------------------------------------

      (pkgs.writeShellScriptBin "install-antigravity" ''
        set -euo pipefail
        echo "Downloading and installing Antigravity CLI..."
        curl -fsSL https://antigravity.google/cli/install.sh | bash
      '')

      (pkgs.writeShellScriptBin "install-claude-code" ''
        set -euo pipefail
        echo "Downloading and installing Claude Code..."
        curl -fsSL https://claude.ai/install.sh | bash
      '')

      # Convenience: install both agents in one go.
      (pkgs.writeShellScriptBin "install-agents" ''
        set -euo pipefail
        echo "Downloading and installing Antigravity CLI..."
        curl -fsSL https://antigravity.google/cli/install.sh | bash
        echo "Downloading and installing Claude Code..."
        curl -fsSL https://claude.ai/install.sh | bash
        echo "✅ Both agents installed."
      '')

      # ---------------------------------------------------------------------------
      # Wrappers (same pattern for both tools: locate the real binary or tell the
      # user which installer to run)
      # ---------------------------------------------------------------------------

      # The real Antigravity CLI is invoked via 'agy'
      (pkgs.writeShellScriptBin "agy" ''
        set -euo pipefail

        if [ -x /root/.local/bin/agy ]; then
          CLI="/root/.local/bin/agy"
        elif [ -x /root/bin/agy ]; then
          CLI="/root/bin/agy"
        else
          echo "Antigravity CLI (agy) not found in expected locations."
          echo "Please run 'install-antigravity' first."
          exit 1
        fi

        exec "$CLI" "$@"
      '')

      # The real Claude Code binary is invoked via 'claude'
      # (the native installer drops it at /root/.local/bin/claude)
      (pkgs.writeShellScriptBin "claude" ''
        set -euo pipefail

        if [ -x /root/.local/bin/claude ]; then
          CLI="/root/.local/bin/claude"
        elif [ -x /root/bin/claude ]; then
          CLI="/root/bin/claude"
        else
          echo "Claude Code (claude) not found in expected locations."
          echo "Please run 'install-claude-code' first."
          exit 1
        fi

        exec "$CLI" "$@"
      '')

      # ---------------------------------------------------------------------------
      # Session restore
      # ---------------------------------------------------------------------------

      # Resume the last Antigravity conversation based on .sessions/sessions.txt
      (pkgs.writeShellScriptBin "restore" ''
        set -euo pipefail

        SESSION_FILE="/workspace/.sessions/sessions.txt"

        if [ ! -f "$SESSION_FILE" ]; then
          echo "Error: No session file found at $SESSION_FILE"
          echo "Are you sure you have started a session in this workspace?"
          exit 1
        fi

        echo "Select a previous conversation to restore:"
        SELECTION=$(cat "$SESSION_FILE" | fzf --prompt="Resume Session > ")

        if [ -z "$SELECTION" ]; then
          echo "No session selected. Aborting."
          exit 0
        fi

        # Extract just the first word (the UUID)
        CONV_ID=$(echo "$SELECTION" | awk '{print $1}')

        echo "Resuming session: $CONV_ID"

        exec agy --conversation="$CONV_ID"
      '')

      # Claude Code has built-in session management, so 'restore-claude' just hands
      # off to its interactive picker. (Equivalent to running 'claude --resume'.)
      (pkgs.writeShellScriptBin "restore-claude" ''
        set -euo pipefail
        exec claude --resume
      '')
    ];
    config = {
      Entrypoint = [ "${entrypoint}/bin/agent-entrypoint" ];
      Cmd = [ "/bin/bash" ];
      Env = [
        "PATH=/bin:/usr/bin:/usr/local/bin"
        "HOME=/root"
        "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        "CURL_CA_BUNDLE=/etc/ssl/certs/ca-bundle.crt"
        "GIT_SSL_CAINFO=/etc/ssl/certs/ca-bundle.crt"
        # Tell the system where to look for standard C libraries
        "LD_LIBRARY_PATH=/lib"
        # Enable flakes, and disable the build sandbox: Nix's sandbox needs nested
        # user/mount namespaces that aren't available inside rootless Podman, so
        # 'nix flake check' / 'nix build' would otherwise fail. Emptying
        # build-users-group runs builds single-user (as root), which is what we want
        # in a throwaway container.
        "NIX_CONFIG=experimental-features = nix-command flakes\nsandbox = false\nbuild-users-group ="
        # Point <nixpkgs> at the flake's own pinned nixpkgs source so the classic
        # commands (nix-shell -p, nix-env, anything importing <nixpkgs>) resolve
        # without a registered channel. The image ships no channels and NIX_PATH is
        # otherwise empty, so without this 'nix-shell -p hello' fails with
        # "file 'nixpkgs' was not found in the Nix search path". Referencing
        # pkgs.path here also pulls the nixpkgs source into the image closure, so
        # this needs no network and matches the version the sandbox is built from.
        "NIX_PATH=nixpkgs=${pkgs.path}"
      ];
      WorkingDir = "/workspace";
    };
  };

  sandboxRunner = pkgs.writeShellScriptBin "agent-sandbox" ''
    set -euo pipefail

    if [ -z "''${1:-}" ]; then
      echo "Error: Please provide a directory to mount."
      echo "Usage: agent-sandbox <directory-to-mount> [agy|claude]"
      echo ""
      echo "  agy      launch the Antigravity CLI directly"
      echo "  claude   launch Claude Code directly"
      echo "  (omit)   drop into an interactive shell with both available"
      exit 1
    fi

    DIR=$(realpath "$1")

    if [ ! -d "$DIR" ]; then
      echo "Error: Directory '$DIR' does not exist."
      exit 1
    fi

    # Optional second argument: which agent to launch directly.
    # Defaults to an interactive shell where both 'agy' and 'claude' are available.
    TOOL="''${2:-shell}"
    case "$TOOL" in
      agy|antigravity)        LAUNCH="agy" ;;
      claude|cc|claude-code)  LAUNCH="claude" ;;
      shell)                  LAUNCH="/bin/bash" ;;
      *)
        echo "Error: Unknown tool '$TOOL'. Use 'agy', 'claude', or omit for a shell."
        exit 1
        ;;
    esac

    # Calculate unique tag based on the Nix store path of the built image
    IMAGE_HASH=$(basename "${sandboxImage}" | cut -d'-' -f1)
    TAG="localhost/agent-sandbox:$IMAGE_HASH"

    if ! ${pkgs.podman}/bin/podman image exists "$TAG"; then
      echo "Building and loading the NixOS-based sandbox image into Podman..."
      ${sandboxImage} | ${pkgs.podman}/bin/podman load
      ${pkgs.podman}/bin/podman tag localhost/agent-sandbox:latest "$TAG"
    fi

    # Per-project state: keyed off the resolved project path, so each project gets
    # its own /root (shell history, agent sessions, any Nix profile installed with
    # 'nix profile install'). This keeps one project's installed toolchain/session
    # history from bleeding into another's.
    PROJECT_SLUG=$(basename "$DIR" | tr -c 'a-zA-Z0-9_.-' '-')
    PROJECT_HASH=$(echo -n "$DIR" | sha256sum | cut -c1-12)
    PROJECT_VOL="agent-project-''${PROJECT_SLUG}-''${PROJECT_HASH}"
    ${pkgs.podman}/bin/podman volume create "$PROJECT_VOL" >/dev/null 2>&1 || true

    # Shared secrets volume: only gh's own config/auth dir, so 'gh auth login' is a
    # one-time step across every project instead of per-project. Mounted as a
    # nested path under the per-project /root mount above.
    ${pkgs.podman}/bin/podman volume create agent-secrets >/dev/null 2>&1 || true

    # Shared Claude auth volume: the Claude Code OAuth credentials and account
    # seed, so 'claude' login is a one-time step across every project. Wired
    # into ~/.claude by the entrypoint; nested under /root like agent-secrets.
    ${pkgs.podman}/bin/podman volume create agent-claude-auth >/dev/null 2>&1 || true

    ${lib.optionalString (sb.skillsRepo != null) ''
      # Shared skills volume: one clone of the skills repo (working-style rules
      # and personal skills) for all projects. The entrypoint pulls it on every
      # start and copies it into ~/.claude, so a merged PR in that repo reaches
      # every sandbox on its next start. Nested under the per-project /root
      # mount, like agent-secrets.
      ${pkgs.podman}/bin/podman volume create agent-skills >/dev/null 2>&1 || true
    ''}

    # Opt-in: persist the container's Nix store so flake builds don't re-fetch the
    # world every session. Run with: PERSIST_NIX_STORE=1 agent-sandbox <dir>
    #
    # This is a NAMED volume (Podman seeds it from the image's /nix on first use via
    # copy-up), keyed to the image hash so an image rebuild gets a fresh, correctly
    # seeded store instead of dangling symlinks. We do NOT bind-mount the host's /nix:
    # that would shadow the image's baked store and break the container's own binaries.
    NIX_ARGS=()
    if [ "''${PERSIST_NIX_STORE:-0}" = "1" ]; then
      NIX_VOL="agent-nix-$IMAGE_HASH"
      ${pkgs.podman}/bin/podman volume create "$NIX_VOL" >/dev/null 2>&1 || true
      NIX_ARGS=(-v "$NIX_VOL:/nix")
    fi

    SKILLS_ARGS=()
    ${lib.optionalString (sb.skillsRepo != null) ''
      SKILLS_ARGS=(-v agent-skills:/root/skills:rw)
    ''}

    echo ""
    echo "================================================="
    echo "🚀 Starting AI Agent Sandbox"
    echo "📁 Mounted Workspace: $DIR -> /workspace"
    echo "💾 Mounted Project State: $PROJECT_VOL -> /root"
    echo "🔑 Mounted Secrets: agent-secrets -> /root/.config/gh"
    echo "🔐 Mounted Claude auth: agent-claude-auth -> /root/.claude-auth (login once, shared everywhere)"
    ${lib.optionalString (sb.skillsRepo != null) ''
      echo "📚 Mounted Skills: agent-skills -> /root/skills (synced into ~/.claude on start)"
    ''}
    if [ "''${PERSIST_NIX_STORE:-0}" = "1" ]; then
      echo "📦 Persistent Nix store: agent-nix-$IMAGE_HASH -> /nix"
    fi
    echo "================================================="
    echo "💡 First-time setup:"
    echo "     install-antigravity   # Antigravity CLI  (run with: agy)"
    echo "     install-claude-code   # Claude Code      (run with: claude)"
    echo "     install-agents        # install both at once"
    echo "💡 Resume a session:"
    echo "     restore               # pick a past Antigravity session"
    echo "     claude --continue     # resume the latest Claude Code session"
    echo "     claude --resume       # pick a past Claude Code session (or: restore-claude)"
    echo "💡 Validate your flake:"
    echo "     nix flake check        # full: evaluates AND builds every host"
    echo "     nix flake show         # fast: structure + eval only"
    echo "💡 Project toolchains (e.g. Go, Node):"
    echo "     nix develop             # if the project has a flake.nix/shell.nix"
    echo "     nix shell nixpkgs#deno  # ad hoc, for this session only (go and node are preinstalled)"
    echo "     nix-shell -p deno       # classic form works too (<nixpkgs> is the pinned source)"
    echo "     (run with PERSIST_NIX_STORE=1 to cache downloads across sessions)"
    echo "================================================="

    # Hardening: block in-container privilege escalation and cap resources so a
    # runaway agent or build cannot starve the host. Limits are overridable via
    # env (SANDBOX_MEMORY, SANDBOX_CPUS, SANDBOX_PIDS); set one to empty to drop
    # that specific limit (useful if your host lacks rootless cgroup delegation).
    HARDEN_ARGS=( --security-opt=no-new-privileges )
    [ -n "''${SANDBOX_MEMORY-8g}" ]  && HARDEN_ARGS+=( --memory="''${SANDBOX_MEMORY-8g}" )
    [ -n "''${SANDBOX_CPUS-4}" ]     && HARDEN_ARGS+=( --cpus="''${SANDBOX_CPUS-4}" )
    [ -n "''${SANDBOX_PIDS-2048}" ]  && HARDEN_ARGS+=( --pids-limit="''${SANDBOX_PIDS-2048}" )

    exec ${pkgs.podman}/bin/podman run -it --rm \
      --security-opt=label=disable \
      "''${HARDEN_ARGS[@]}" \
      "''${NIX_ARGS[@]}" \
      "''${SKILLS_ARGS[@]}" \
      -v "$PROJECT_VOL:/root:rw" \
      -v agent-secrets:/root/.config/gh:rw \
      -v agent-claude-auth:/root/.claude-auth:rw \
      -v "$DIR:/workspace:rw" \
      "$TAG" "$LAUNCH"
  '';
in
{
  imports = [ ../modules/options.nix ];

  environment.systemPackages = [ sandboxRunner ];
}
