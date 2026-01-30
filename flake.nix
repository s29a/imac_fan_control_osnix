{
  description = "iMac 12,2 Fan Control - C++ rewrite with PID and NVML";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      in
      {
        # Среда для разработки (nix develop)
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            gcc
            cmake
            pkg-config
            clang-tools # Для LSP (clangd) в Neovim
            gdb
          ];
          buildInputs = with pkgs; [
            linuxPackages.nvidia_x11 # Заголовки и либы NVML
          ];

          shellHook = ''
            echo "--- iMac Fan Control CPP Dev Shell ---"
            # Генерируем базу данных команд для Neovim
            if [ -f "CMakeLists.txt" ]; then
              cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
              ln -sf build/compile_commands.json .
            fi
          '';
        };

        # Пакет для установки (nix build)
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "imac-fan-control";
          version = "0.2.0";
          src = ./.;
          nativeBuildInputs = with pkgs; [ cmake pkg-config ];
          buildInputs = with pkgs; [ linuxPackages.nvidia_x11 ];
        };
      }
    );
}
