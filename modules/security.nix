# securityPolicy -> generated `scripts` (DSC WindowsPowerShellScript) that
# compare and apply only the declared keys through secedit and auditpol.
# Empty (the default) renders nothing.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.securityPolicy;

  helpers = builtins.readFile ./secpol.ps1;
  # Values travel as JSON inside a single-quoted PowerShell string.
  policy =
    v:
    "$Policy = '${
      lib.replaceStrings [ "'" ] [ "''" ] (builtins.toJSON v)
    }' | ConvertFrom-Json\n${helpers}\n";
  secedit = { inherit (cfg) userRights account; };
  audit = { inherit (cfg) audit; };

  guid = "\\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}}";
in
{
  options.securityPolicy = {
    userRights = mkOption {
      type = types.attrsOf (types.listOf (types.strMatching "S-1-[0-9-]+"));
      default = { };
      example = {
        SeLockMemoryPrivilege = [ "S-1-5-32-544" ];
      };
      description = ''
        Privilege constant -> exact set of SIDs holding it ([] = nobody).
        SIDs only: account names are localised. Undeclared rights are left alone.
      '';
    };
    account = mkOption {
      type = types.attrsOf (types.either types.int types.str);
      default = { };
      example = {
        MinimumPasswordLength = 0;
        LockoutBadCount = 0;
      };
      description = "secedit [System Access] keys (password, lockout, guest/admin account settings).";
    };
    audit = mkOption {
      type = types.attrsOf (
        types.enum [
          "none"
          "success"
          "failure"
          "both"
        ]
      );
      default = { };
      example = {
        "{0CCE9215-69AE-11D9-BED3-505054503030}" = "both";
      };
      description = "Advanced audit policy: subcategory GUID (with braces) -> setting. Names are localised, GUIDs are not.";
    };
  };

  config = {
    assertions = map (g: {
      assertion = builtins.match guid g != null;
      message = "securityPolicy.audit: '${g}' is not a {GUID}";
    }) (lib.attrNames cfg.audit);

    scripts =
      lib.optionalAttrs (cfg.userRights != { } || cfg.account != { }) {
        "Security policy" = {
          test = policy secedit + "@(Get-SecPolicyDrift $Policy).Count -eq 0";
          set = policy secedit + "Set-SecPolicy $Policy";
        };
      }
      // lib.optionalAttrs (cfg.audit != { }) {
        "Audit policy" = {
          test = policy audit + "@(Get-AuditPolicyDrift $Policy).Count -eq 0";
          set = policy audit + "Set-AuditPolicy $Policy";
        };
      };
  };
}
