#! /bin/bash

install_pgai() {
    whereis git
    pushd /tmp
      git clone https://github.com/timescale/pgai.git --branch extension-0.8.0
      pushd pgai
        python3 -m venv venv/
        . venv/bin/activate
        python3 -m pip install --upgrade pip
        projects/extension/build.py install
      popd
      rm -r pgai
    popd
}

install_pgai