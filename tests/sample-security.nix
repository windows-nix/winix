# Sample host for the `sample-security` flake check: securityPolicy plus an
# adapted PSDSC resource. Not a real machine.
{ wlib, ... }:
{
  securityPolicy = {
    userRights.SeLockMemoryPrivilege = [ "S-1-5-32-544" ];
    account.LockoutBadCount = 0;
    audit."{0CCE9215-69AE-11D9-BED3-505054503030}" = "both";
  };
  dsc.modules.AuditPolicyDsc = {
    version = "1.4.0.0";
    hash = "sha256-Z1SqayAyKtSrkPq6MQ5YO2oTKIlA3ZZZS3X8xxKhvLs=";
  };
  dsc.resources = [
    (wlib.psdsc {
      name = "Audit logoff";
      type = "AuditPolicyDsc/AuditPolicySubcategory";
      properties = {
        Name = "Logoff";
        AuditFlag = "Success";
        Ensure = "Present";
      };
    })
  ];
}
