let pkgs = import <nixpkgs> {};
    make = haskell : haskell.callPackage ./expressionTesting.nix {
        expressionTestingSrc = ./dist/expressionTesting-0.1.2.tar.gz;
    };
in rec {
    current = make pkgs.haskellPackages;
    ghc783 = make pkgs.haskellPackages_ghc783;
    ghc763 = make pkgs.haskellPackages_ghc763;
    ghc742 = make pkgs.haskellPackages_ghc742;
    ghc722 = make pkgs.haskellPackages_ghc722;
    ghc704 = make pkgs.haskellPackages_ghc704;
}
