#! /bin/bash
set -euo pipefail

install_pgai() {
    whereis git
    pushd /tmp
      git clone https://github.com/timescale/pgai.git --branch extension-0.8.0
      pushd pgai
        python3.12 -m venv venv/
        # shellcheck disable=SC1091
        . venv/bin/activate
        python3.12 -m pip install --upgrade pip
        projects/extension/build.py install
        deactivate
      popd
      rm -r pgai
    popd
}

install_langchain() {
  python3.12 -m pip install --break-system-packages langchain
}

install_packages() {
  apt-get update
  /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
  apt-get install postgresql-17-pgvector
  apt-get install -y postgresql-plpython3-17
}

install_packages
install_pgai
install_langchain