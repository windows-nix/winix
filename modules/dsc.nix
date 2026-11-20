# registry / startup / features / power / scripts / dsc.resources
#   -> config.dsc.yaml + config.win11.dsc.yaml (DSC v3, resources with
#      minBuild > 19045 go to the win11 document; apply skips it below 22000).
{
  lib,
  config,
  pkgs,
  wlib,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config;

  valueData = types.attrTag (
    lib.genAttrs [ "String" "ExpandString" ] (_: mkOption { type = types.str; })
    // {
      MultiString = mkOption { type = types.listOf types.str; };
      Binary = mkOption { type = types.listOf (types.ints.between 0 255); };
      DWord = mkOption { type = types.ints.u32; };
      QWord = mkOption { type = types.ints.unsigned; };
    }
  );
  regValue = types.either valueData (
    types.submodule {
      options = {
        value = mkOption {
          type = types.nullOr valueData;
          default = null;
        };
        exist = mkOption {
          type = types.bool;
          default = true;
          description = "false deletes the value.";
        };
        minBuild = mkOption {
          type = types.int;
          default = 0;
        };
      };
    }
  );
  norm =
    v:
    if v ? value || v ? exist || v ? minBuild then
      v
    else
      {
        value = v;
        exist = true;
        minBuild = 0;
      };

  regResource =
    keyPath: valueName: v:
    let
      n = norm v;
    in
    {
      name = "${keyPath}\\${valueName}";
      type = "Microsoft.Windows/Registry";
      inherit (n) minBuild;
      properties = {
        _exist = n.exist;
        inherit keyPath valueName;
      }
      // lib.optionalAttrs (n.exist && n.value != null) { valueData = n.value; };
    };

  script = name: s: {
    inherit name;
    type = "Microsoft.DSC.Transitional/WindowsPowerShellScript";
    inherit (s) minBuild;
    properties = {
      testScript = s.test;
      setScript = s.set;
    }
    // lib.optionalAttrs (s.get != null) { getScript = s.get; };
  };

  # powercfg output is localised: match GUIDs and hex indices only.
  # A list, not an attrset: the sleep script edits the active scheme, so it
  # must run after the scheme is activated.
  powerScripts =
    lib.optional (cfg.power.scheme != null) {
      name = "Power plan ${cfg.power.scheme.name}";
      value =
        let
          g = cfg.power.scheme.guid;
        in
        {
          # Not [bool](...): DSC parses a string starting with '[' as an expression.
          test = "(powercfg /getactivescheme) -match '${g}'";
          set = ''
            if (-not ((powercfg /list) -match '${g}')) {
              powercfg /duplicatescheme ${cfg.power.scheme.template} ${g} | Out-Null
            }
            powercfg /setactive ${g}
            if ($LASTEXITCODE) { throw "powercfg /setactive ${g} failed" }
          '';
        };
    }
    ++ lib.optional (cfg.power.standbyTimeout != null) {
      name = "Sleep after ${toString cfg.power.standbyTimeout.ac}/${toString cfg.power.standbyTimeout.dc} min (AC/DC)";
      value =
        let
          hex = m: "0x" + lib.fixedWidthString 8 "0" (lib.toLower (lib.toHexString (m * 60)));
          query = "$v = powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE | Select-String '0x[0-9a-f]+' -AllMatches | ForEach-Object { $_.Matches.Value }";
        in
        {
          # The last two hex values are the AC and DC current indices.
          test = ''
            ${query}
            ($v[-2] -eq '${hex cfg.power.standbyTimeout.ac}') -and ($v[-1] -eq '${hex cfg.power.standbyTimeout.dc}')
          '';
          set = ''
            powercfg /change standby-timeout-ac ${toString cfg.power.standbyTimeout.ac}
            powercfg /change standby-timeout-dc ${toString cfg.power.standbyTimeout.dc}
          '';
        };
    };

  scriptType = types.submodule {
    options = {
      test = mkOption {
        type = types.str;
        description = "PowerShell 5.1; returns true when in the desired state.";
      };
      set = mkOption { type = types.str; };
      get = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      minBuild = mkOption {
        type = types.int;
        default = 0;
      };
    };
  };

  resources =
    lib.concatLists (lib.mapAttrsToList (k: vs: lib.mapAttrsToList (regResource k) vs) cfg.registry)
    ++ lib.mapAttrsToList (name: e: {
      name = "Run: ${name}";
      type = "Microsoft.Windows/Registry";
      minBuild = 0;
      properties = {
        _exist = true;
        keyPath = "${
          if e.scope == "machine" then "HKLM" else "HKCU"
        }\\Software\\Microsoft\\Windows\\CurrentVersion\\Run";
        valueName = name;
        valueData.String = wlib.envString e.command;
      };
    }) cfg.startup
    ++ lib.optional (cfg.features != { }) {
      name = "Optional features";
      type = "Microsoft.Windows/OptionalFeatureList";
      minBuild = 0;
      properties.features = lib.mapAttrsToList (featureName: state: {
        inherit featureName state;
      }) cfg.features;
    }
    ++ map (
      p:
      script p.name (
        {
          get = null;
          minBuild = 0;
        }
        // p.value
      )
    ) powerScripts
    ++ lib.mapAttrsToList script cfg.scripts
    ++ map (r: { minBuild = 0; } // r) cfg.dsc.resources;

  winPsAdapters = [
    "Microsoft.Adapter/WindowsPowerShell"
    "Microsoft.Windows/WindowsPowerShell"
  ];
  isWin11 = r: r.minBuild > 19045;
  # JSON is valid YAML; dsc reads either.
  doc =
    name: rs:
    pkgs.writeText name (
      builtins.toJSON {
        "$schema" = "https://aka.ms/dsc/schemas/v3/bundled/config/document.json";
        resources = map (r: removeAttrs r [ "minBuild" ]) rs;
      }
    );
in
{
  options = {
    registry = mkOption {
      type = types.attrsOf (types.attrsOf regValue);
      default = { };
      example = lib.literalExpression ''{ "HKCU\\Software\\X"."Value" = { DWord = 1; }; }'';
      description = "keyPath -> valueName -> valueData, or { value; exist; minBuild; }. \"\" is the default value.";
    };
    startup = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            command = mkOption {
              type = types.str;
              description = "%VAR% references are resolved by dsc.exe at apply time.";
            };
            scope = mkOption {
              type = types.enum [
                "user"
                "machine"
              ];
              default = "user";
            };
          };
        }
      );
      default = { };
      description = "Autostart entries (Run key values).";
    };
    features = mkOption {
      type = types.attrsOf (
        types.enum [
          "Installed"
          "NotPresent"
          "Removed"
        ]
      );
      default = { };
      description = "Windows optional features (DISM names).";
    };
    power = {
      scheme = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              name = mkOption { type = types.str; };
              guid = mkOption { type = types.str; };
              template = mkOption {
                type = types.str;
                description = "Scheme GUID duplicated under `guid` when it does not exist yet.";
              };
            };
          }
        );
        default = null;
      };
      standbyTimeout = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              ac = mkOption { type = types.ints.unsigned; };
              dc = mkOption { type = types.ints.unsigned; };
            };
          }
        );
        default = null;
        description = "Minutes; 0 = never.";
      };
    };
    scripts = mkOption {
      type = types.attrsOf scriptType;
      default = { };
      description = "Imperative bits with an idempotence check (DSC Script semantics).";
    };
    dsc.resources = mkOption {
      type = types.listOf types.attrs;
      default = [ ];
      description = ''
        Raw DSC v3 resources ({ name; type; properties; minBuild ? 0; directives ? ...; dependsOn ? ...; }),
        appended last. Adapted PSDSC resources: wlib.psdsc.
      '';
    };
    dsc.modules = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            version = mkOption { type = types.str; };
            hash = mkOption { type = types.str; };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''{ SecurityPolicyDsc = { version = "2.10.0.0"; hash = "sha256-..."; }; }'';
      description = ''
        PowerShell Gallery modules providing PSDSC resources, pinned by version and hash.
        apply installs them machine-wide (%ProgramFiles%\WindowsPowerShell\Modules), the
        only place PSDSC 1.1 finds them.
      '';
    };
    dsc.winrm = mkOption {
      type = types.bool;
      default = lib.any (
        r: lib.elem (r.directives.requireAdapter or null) winPsAdapters
      ) cfg.dsc.resources;
      defaultText = "true when a resource requires a Windows PowerShell adapter";
      description = ''
        PSDSC 1.1 (the Windows PowerShell adapter) needs WinRM. If WinRM is stopped, apply
        starts it with loopback-only listeners for the DSC phase and restores the previous
        service and listener state afterwards.
      '';
    };
    dsc.documents = mkOption {
      type = types.attrsOf types.package;
      internal = true;
      readOnly = true;
    };
  };

  config.dsc.documents = {
    "config.dsc.yaml" = doc "config.dsc.yaml" (lib.filter (r: !isWin11 r) resources);
    "config.win11.dsc.yaml" = doc "config.win11.dsc.yaml" (lib.filter isWin11 resources);
  };
}
