# Entry points of the Windows module system (README.md).
{ lib }:
rec {
  # evalModules over modules/ + host modules; the folder is
  # `(windowsConfiguration { ... }).config.build.folder`.
  windowsConfiguration =
    {
      pkgs,
      modules,
      specialArgs ? { },
    }:
    lib.evalModules {
      modules = [ ./modules ] ++ modules;
      specialArgs = {
        inherit pkgs wlib;
      }
      // specialArgs;
    };

  # Helpers for host modules (also a module argument).
  wlib = {
    dword = n: { DWord = n; };
    str = s: { String = s; };
    win11 = value: {
      inherit value;
      minBuild = 22000;
    };
    # Adapted PSDSC resource (`<Module>/<Resource>`, module pinned in dsc.modules),
    # run through Windows PowerShell 5.1; enables dsc.winrm.
    psdsc =
      r: lib.recursiveUpdate { directives.requireAdapter = "Microsoft.Adapter/WindowsPowerShell"; } r;
    # "%LOCALAPPDATA%\\x" -> DSC expression resolved by dsc.exe in the apply
    # process, so per-user paths need no PowerShell.
    envString =
      s:
      let
        parts = lib.filter (p: p != "") (
          map (
            p: if lib.isList p then "envvar('${lib.head p}')" else "'${lib.replaceStrings [ "'" ] [ "''" ] p}'"
          ) (builtins.split "%([A-Za-z_][A-Za-z0-9_()]*)%" s)
        );
        expr =
          if lib.length parts == 1 then lib.head parts else "concat(${lib.concatStringsSep ", " parts})";
      in
      if lib.hasInfix "%" s then "[${expr}]" else s;
  };
}
