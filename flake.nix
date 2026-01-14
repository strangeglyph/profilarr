{
  description = "Package Profilarr for nix consumption";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;

      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./backend; };

      overlay = workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
      };

      overrides = final: prev:
        let
          inherit (final) resolveBuildSystem;
          inherit (builtins) mapAttrs;
          buildSystemOverrides = {
            "regex".setuptools = [];
          };
        in
        mapAttrs (
          name: spec:
          prev.${name}.overrideAttrs (old: {
            nativeBuildInputs = old.nativeBuildInputs ++ resolveBuildSystem spec;
          })
        ) buildSystemOverrides;

      pythonSets = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          python = lib.head (pyproject-nix.lib.util.filterPythonInterpreters {
            inherit (workspace) requires-python;
            inherit (pkgs) pythonInterpreters;
          });
        in
        (pkgs.callPackage pyproject-nix.build.packages {
          inherit python;
        }).overrideScope
          (
            lib.composeManyExtensions [
              pyproject-build-systems.overlays.wheel
              overlay
              overrides
            ]
          )
      );

    in
    {
      packages = forAllSystems (system:
        let
          pythonSet = pythonSets.${system};
          pkgs = nixpkgs.legacyPackages.${system};
          profilarr-packages = self.outputs.packages.${system};
          inherit (pkgs.callPackages pyproject-nix.build.util { }) mkApplication;
        in
        {
          virtual-env = (pythonSet.mkVirtualEnv "profilarr-env" workspace.deps.default)
                          .overrideAttrs (old: {
                            #venvIgnoreCollisions = old.venvIgnoreCollisions ++ [ "*/fastapi" ];
                          });

          frontend = pkgs.buildNpmPackage rec {
            pname = "profilarr-frontend";
            version = "0.0.0-nix";

            src = ./frontend;
            npmDeps = pkgs.importNpmLock {
              npmRoot = ./frontend;
            };

            npmConfigHook = pkgs.importNpmLock.npmConfigHook;

            path_prefix = "";

            postInstall = ''
              cp -r dist $out/static
            '';
          };

          default = pkgs.symlinkJoin {
            name = "profilarr";
            version = profilarr-packages.frontend.version;

            paths = [
              profilarr-packages.frontend
              profilarr-packages.virtual-env
            ];
          };
        }
      );

      overlays.default = final: prev: {
        profilarr = self.outputs.packages."${prev.stdenv.hostPlatform.system}".default;
      };

      nixosModules.default = {
        imports = [ ./module.nix ];
        config.nixpkgs.overlays = [ self.outputs.overlays.default ];
      };

      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
          {
            default = pkgs.testers.runNixOSTest {
              name = "profilarr integration test";
              node.pkgsReadOnly = false;
              sshBackdoor.enable = true;

              nodes.machine = { config, pkgs, ...}: {
                imports = [ self.outputs.nixosModules.default ];
                config = {
                  services.profilarr = {
                    enable = true;
                    port = 12345;
                  };
                };
              };
              testScript = { nodes, ... }: ''
                machine.wait_for_unit("profilarr.service")
                machine.wait_for_open_port(12345)

                machine.succeed("curl --fail 'http://[::1]:12345/'")
              '';
            };
          }
      );
    };
}