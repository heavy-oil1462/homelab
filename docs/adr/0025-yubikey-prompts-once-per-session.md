# ADR-0025: YubiKey prompts on workstations: once per session, PIN where it matters

Status: Accepted

## Context

On a workstation the owner gave the YubiKey's PIN and a touch for every
SSH connection, every git operation over SSH and every sudo. DIRECTION.md's
security principle says the owner authenticates once per thing, and that
each layer is sized to the realistic threats: laptop theft, burglary, a
compromised LAN or IoT device, phishing and malware on a workstation. The
owner accepted the security review's proposal 4, fewer prompts (question
01a2033d-c70f, 2026-11-22), and approved this record.

What each prompt guards:

- **Login and the screen lock** (greetd, hyprlock) stand between a stolen
  or unattended laptop and the owner's session. The PIN is what a thief
  with the key in the laptop lacks.
- **sudo** runs inside a session that was opened with PIN and touch.
  Malware in that session can wait for the owner's next sudo, or read
  what the owner types, so a PIN there adds little; a touch still means
  nothing becomes root without the owner at the key.
- **SSH** uses the key's FIDO2 `sk` credentials with verify-required. Each
  connection is a new signature on the key, so a new PIN and touch.

pam_u2f's options are global in `security.pam.u2f.settings`, which
nixpkgs copies into the `u2f` rule of every service that enables it. The
pinned nixpkgs declares those rules as options
(`security.pam.services.<name>.rules.auth.u2f.settings`), so one service's
setting can be overridden. pam_u2f 1.4.0 asks for the PIN when
`pinverification=1` or when the credential in the authfile carries
`+pin` (enrolled with `pamu2fcfg -N`); with `pinverification=0` and no
`+pin` it asks for none (`util.c`).

yubikey-agent was enabled and pointed `SSH_AUTH_SOCK` at its socket. It
serves keys from the YubiKey's PIV applet. The owner's SSH keys are FIDO2
`sk` keys, which it does not serve. An agent cannot cache FIDO user
verification for those either: ssh-agent holds only the key handle, and
the authenticator checks the PIN and the touch itself for every
signature. Nothing on the host can remember a PIN entry for the next
signature, so fewer prompts for SSH means fewer signatures.

## Decision

- **Login and screen lock keep PIN and touch.** The global setting stays
  `pinverification=1`; login, greetd (which includes login's stack) and
  hyprlock use it, and so does `su`.
- **sudo takes a touch without the PIN.** `modules/yubikey.nix` sets
  sudo's `u2f` rule to `pinverification=0` and `userpresence=1`, and sudo's
  `timestamp_timeout` to 15 minutes, so a burst of sudo in one terminal is
  one touch. Keys are enrolled without `-N`.
- **SSH shares one connection per host.** The workstation role writes a
  `Match originalhost <patterns> localuser <user>` block into the system
  ssh_config with `ControlMaster auto`, `ControlPath
  /run/user/%i/ssh-%C` and `ControlPersist 4h`, for the host patterns in
  `homelab.workstation.sshSharedHosts` (default empty). The site lists its
  servers and Forgejo's SSH host. The first ssh or git command to a host
  takes PIN and touch; the following ones go over that connection. The
  socket is in the user's runtime directory, mode 0700 and cleared at
  logout. The block matches the owner's user only, as ssh exits when it
  cannot create the socket, and a user without a session, such as root
  under sudo, has no `/run/user/<uid>`.
- **yubikey-agent is removed.** The role sets no other agent, so
  `SSH_AUTH_SOCK` is unset and ssh reads the `sk` key handles from
  `~/.ssh`.

## Consequences

- A shared connection outlives its last session by up to 4 hours, and
  stays usable when the YubiKey is unplugged in that time: anything
  running as the owner can open new sessions over it without the key.
  That is accepted as one working session, like an unlocked desktop; it
  ends at logout, at reboot, with `ssh -O exit <host>`, or after 4 hours
  idle. Malware in the session could already wait for the owner's next
  connection.
- A touch alone gets root from the owner's session for 15 minutes per
  terminal. Someone at an unlocked, unattended laptop with the key in it
  gets root with a touch; the screen lock is what guards against that.
- A credential enrolled with `-N` keeps asking for the PIN at sudo. Hosts
  that set `SSH_AUTH_SOCK` to yubikey-agent's socket themselves drop
  that; PIV keys served by it stop working.
- Host patterns match the name as typed on the command line or in a Git
  remote, not the resolved address. A host reached under another name is
  not shared.
- The `yubikey-prompts` check holds the example workstation to this: the
  PAM stacks of login, greetd, hyprlock and sudo, sudo's timestamp, no
  yubikey-agent, and ssh_config read by `ssh -G`. Prompts against a real
  key are tested by hand.
- Changes to these prompts stay Ask-the-owner-first (DIRECTION.md).

Related: [ADR-0024](0024-break-glass-ssh-from-the-lan.md) (SSH access to
the servers), DIRECTION.md's principle that security is proportionate and
even.
