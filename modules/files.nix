# files / boot.actions / manualSteps -> machine.json + startup.json.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;

  holder = types.submodule {
    options = {
      process = mkOption {
        type = types.str;
        description = "Process name without .exe.";
      };
      start = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "What to restart; null = the stopped process's own path. %VAR% is expanded.";
      };
      args = mkOption {
        type = types.str;
        default = "";
      };
    };
  };

  file = types.submodule {
    options = {
      root = mkOption {
        type = types.enum [
          "LocalAppData"
          "RoamingAppData"
          "ProgramData"
          "ProgramFiles"
          "ProgramFilesX86"
          "UserProfile"
        ];
        description = "Per-user roots resolve for the account running apply.";
      };
      path = mkOption {
        type = types.str;
        description = "Relative to root, backslash-separated.";
      };
      format = mkOption {
        type = types.enum [
          "json"
          "ini"
          "text"
        ];
      };
      json = mkOption {
        type = types.attrs;
        default = { };
        description = "Merged into the file key by key (nested attrsets recurse); other keys stay the app's.";
      };
      ini = mkOption {
        type = types.attrsOf (types.attrsOf types.str);
        default = { };
        description = "section -> key -> value; other keys stay the app's.";
      };
      text = mkOption {
        type = types.str;
        default = "";
        description = "Whole file content (format = text).";
      };
      holders = mkOption {
        type = types.listOf holder;
        default = [ ];
        description = ''
          Processes that hold the file in memory and overwrite it on exit.
          Stopped before a write, restarted after it in their owner's session.
        '';
      };
      requires = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Paths (%VAR% expanded) that must exist, else the file is skipped.";
      };
      minBuild = mkOption {
        type = types.int;
        default = 0;
      };
    };
  };

  bootValue = types.nullOr (types.either types.bool types.str);
in
{
  options = {
    files = mkOption {
      type = types.attrsOf file;
      default = { };
      description = ''
        App config files. JSON/INI string values have %VAR% expanded at apply
        time. Applied in name order; holders restart after all writes, in the
        same order.
      '';
    };
    boot.actions = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            kind = mkOption {
              type = types.enum [
                "ServiceStartType"
                "Service"
                "PnpDevice"
                "MsiInterrupts"
              ];
              description = ''
                ServiceStartType: sc.exe start= value (boot/system/auto/demand/disabled).
                Service: by display or service name; true = automatic + started, false = stopped + disabled.
                PnpDevice: by hardware id; true = enabled.
                MsiInterrupts: PCI vendor prefix (VEN_xxxx); true = MSISupported=1.
              '';
            };
            target = mkOption { type = types.str; };
            vm = mkOption {
              type = bootValue;
              default = null;
              description = "Value on a QEMU/KVM guest; null = no action.";
            };
            metal = mkOption {
              type = bootValue;
              default = null;
            };
          };
        }
      );
      default = [ ];
      description = "Applied by startup.ps1 at every boot as SYSTEM, per platform.";
    };
    manualSteps = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            text = mkOption { type = types.str; };
            belowBuild = mkOption {
              type = types.nullOr types.int;
              default = null;
              description = "Only listed when the Windows build is below this.";
            };
          };
        }
      );
      default = [ ];
      description = "Printed in the apply summary.";
    };
  };

  config.assertions = lib.mapAttrsToList (n: f: {
    assertion = (f.format == "json") == (f.json != { }) && (f.format == "ini") == (f.ini != { });
    message = "windows: files.${n}: set exactly the field matching format = ${f.format}";
  }) config.files;
}
