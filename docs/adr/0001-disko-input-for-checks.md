# ADR-0001: disko is a flake input for the checks only
Status: Accepted

## Context

Every exported module should be evaluated by an example so that
`nix flake check` catches breakage. `vm-disko` sets `disko.devices`, an
option that only disko's NixOS module declares. Without that module the
example cannot evaluate at all. A stub option declaring `disko.devices` as
anything would make the evaluation pass while proving nothing about the
layout: no type checking, and none of the `fileSystems` and boot loader
settings disko derives from it.

## Decision

disko (github:nix-community/disko) is an input of this flake, with its
nixpkgs following ours. Only the checks use it: `examples/vm.nix` is
evaluated with disko's module added, as the `example-vm` check.

The exported modules do not import disko. `vm-disko` stays a plain layout
that consumers combine with the disko module from their own flake, as
before.

## Consequences

- `vm-disko` is type checked against the disko version in `flake.lock`, and
  the VM example gets its root filesystem and GRUB device from the layout.
- `flake.lock` carries one more input to keep current. Consumers who follow
  this flake's inputs do not pull disko into their systems unless they use
  it themselves.
- A disko release the consumer pins may differ from ours; the check proves
  the layout against ours only.
