{ fetchFromGitHub }:
rec {
  pname = "authelia";
  version = "4.38.8";

  src = fetchFromGitHub {
    owner = "authelia";
    repo = "authelia";
    rev = "v${version}";
    hash = "sha256-wuGA3nxzMhpaJKPQeMgVv27zmLyUL5o3MVY+BM6SbAI=";
  };
  vendorHash = "sha256-k+VzAxV9ctvOMxAM6j9qFNOMERxm5Rgcni18dhh3Rfs=";
  npmDepsHash = "sha256-cFgWNh+3IL4qsF4SuTPWZwCcKyq3OFZqhOpx5u35JSg=";
}
