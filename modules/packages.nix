# packages.{common,bareOnly,vmOnly} -> items.json + apply tools.
{ lib, config, ... }:
let
  inherit (lib) mkOption types;
  item = types.submodule {
    options = {
      id = mkOption { type = types.strMatching "[a-z0-9-]+"; };
      name = mkOption { type = types.str; };
      kind = mkOption {
        type = types.enum [
          "auto"
          "installer"
          "msi"
          "zip"
          "msix"
          "driver"
        ];
        default = "auto";
        description = "Installer handling; auto resolves a compatible winget manifest installer.";
      };
      source = mkOption {
        type = types.attrs;
        description = "{ winget = id; } | { github = { repo; asset; }; } | { url; version; }; resolved by sync-pins.";
      };
      silentArgs = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      detect = mkOption {
        type = types.nullOr types.attrs;
        default = null;
        description = "{ displayName = regex; } | { path; } | { productCode; } | { appx; }";
      };
      enable = mkOption {
        type = types.bool;
        default = true;
      };
      minBuild = mkOption {
        type = types.int;
        default = 0;
      };
      extractTo = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      nestedFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Installer inside a zip to run instead of extracting.";
      };
      rootDevice = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Root-enumerated hardware id (e.g. "Root\MttVDD") for kind=driver items
          whose device does not exist until the driver is installed. apply
          creates and binds it (devcon-equivalent) instead of plain pnputil.
        '';
      };
      tool = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Staged as tools/<tool>/<file> for apply itself, not listed in items.json.";
      };
    };
  };
  packageList = mkOption {
    type = types.listOf (types.either types.str item);
    default = [ ];
  };
  wingetId =
    s:
    lib.concatStrings (
      map (c: if builtins.match "[A-Za-z0-9]" c != null then lib.toLower c else "-") (
        lib.stringToCharacters s
      )
    );
  expand =
    i:
    if lib.isString i then
      {
        id = wingetId i;
        name = i;
        kind = "auto";
        source.winget = i;
        silentArgs = null;
        detect = null;
        enable = true;
        minBuild = 0;
        extractTo = null;
        nestedFile = null;
        rootDevice = null;
        tool = null;
      }
    else
      i;
  expandSet = when: values: map (i: { inherit when; } // expand i) values;
in
{
  options = {
    packages = mkOption {
      type = types.submodule {
        options = {
          common = packageList;
          bareOnly = packageList;
          vmOnly = packageList;
        };
      };
      default = { };
      description = "Packages for every platform, bare metal only, or VMs only.";
    };
    packageItems = mkOption {
      type = types.listOf types.attrs;
      internal = true;
      readOnly = true;
      description = "Flattened package sets with the runtime platform selector.";
    };
    pins = mkOption {
      type = types.attrsOf types.attrs;
      default = { };
      description = "id -> resolved download (pins.json from sync-pins).";
    };
  };

  config = {
    packageItems =
      expandSet "any" config.packages.common
      ++ expandSet "metal" config.packages.bareOnly
      ++ expandSet "vm" config.packages.vmOnly;

    assertions =
      let
        ids = map (i: i.id) config.packageItems;
      in
      [
        {
          assertion = lib.length ids == lib.length (lib.unique ids);
          message = "windows: duplicate package ids across common, bareOnly and vmOnly";
        }
      ]
      ++ map (i: {
        assertion = i.kind != "auto" || i.source ? winget;
        message = "windows: ${i.id}: kind = auto requires a winget source";
      }) config.packageItems
      ++ map (i: {
        assertion = !i.enable || config.pins ? ${i.id};
        message = "windows: ${i.id} has no pin; run sync-pins in the host dir";
      }) config.packageItems
      ++ map (i: {
        assertion = !i.enable || i.kind != "auto" || !(config.pins ? ${i.id}) || config.pins.${i.id} ? kind;
        message = "windows: ${i.id}: automatic kind needs a resolved kind in pins.json";
      }) config.packageItems;
  };
}
