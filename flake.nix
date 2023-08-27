{
  description = "Add pod support to podman on nixos";

  outputs = {
    self,
    nixpkgs,
  }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {inherit system;};
  in {
    nixosModules = rec {
      podman-pods = import ./podman.nix;
      default = podman-pods;
    };
    devShells.${system}.default = pkgs.mkShell {
      buildInputs = with pkgs; [
        alejandra
        nixd
      ];
    };
  };
}
