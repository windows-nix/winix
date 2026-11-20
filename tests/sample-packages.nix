{
  packages = {
    common = [
      {
        id = "common-app";
        name = "Common app";
        kind = "installer";
        source = {
          url = "https://example.invalid/common.exe";
          version = "1";
        };
        detect.path = "C:\\Apps\\Common.exe";
      }
      "Publisher.Application"
    ];
    bareOnly = [
      {
        id = "bare-app";
        name = "Bare app";
        kind = "installer";
        source = {
          url = "https://example.invalid/bare.exe";
          version = "1";
        };
        detect.path = "C:\\Apps\\Bare.exe";
      }
    ];
    vmOnly = [
      {
        id = "vm-app";
        name = "VM app";
        kind = "installer";
        source = {
          url = "https://example.invalid/vm.exe";
          version = "1";
        };
        detect.path = "C:\\Apps\\Vm.exe";
      }
    ];
  };

  pins = builtins.listToAttrs (
    map
      (id: {
        name = id;
        value = {
          version = "1";
          url = "https://example.invalid/${id}.exe";
          sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
          file = "${id}.exe";
          silentArgs = null;
          installerType = null;
        }
        // (
          if id == "publisher-application" then
            {
              kind = "msi";
              detect.displayName = "^Publisher Application$";
            }
          else
            { }
        );
      })
      [
        "common-app"
        "bare-app"
        "vm-app"
        "publisher-application"
      ]
  );
}
