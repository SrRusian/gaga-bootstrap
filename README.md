# gaga-bootstrap

Instala un servidor GAGA Platform (Ubuntu 24.04). No contiene secretos.

## Antes (en tu PC)

    ssh-keygen -t ed25519 -C "tu-nombre@pc"
    ssh-keygen -t ed25519 -C gaga-actions -f gaga_actions

## Instalar (en el servidor, como root)

    git clone https://github.com/SrRusian/gaga-bootstrap.git
    bash gaga-bootstrap/bootstrap.sh
