{ config, pkgs, ... }:

let
  cfg = config.homelab;
in
{
  imports = [ ./options.nix ];

  time.timeZone = cfg.timeZone;

  i18n = {
    defaultLocale = cfg.defaultLocale;
    extraLocaleSettings = {
      LC_ADDRESS = cfg.regionalLocale;
      LC_IDENTIFICATION = cfg.regionalLocale;
      LC_MEASUREMENT = cfg.regionalLocale;
      LC_MONETARY = cfg.regionalLocale;
      LC_NAME = cfg.regionalLocale;
      LC_NUMERIC = cfg.regionalLocale;
      LC_PAPER = cfg.regionalLocale;
      LC_TELEPHONE = cfg.regionalLocale;
      LC_TIME = cfg.regionalLocale;
    };
  };

  console.keyMap = cfg.keyboard.consoleKeyMap;
}
