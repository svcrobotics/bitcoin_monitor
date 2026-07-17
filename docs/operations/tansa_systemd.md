# Supervision Tansa avec systemd utilisateur

Tansa development est supervise par une seule unite systemd utilisateur :

```text
tansa-dev.service
└── bin/dev
    └── Foreman
        ├── web
        ├── css
        ├── scheduler
        └── workers Sidekiq dedies
```

`Procfile.dev` est la source unique des processus applicatifs. Aucun worker
metier ne doit etre lance par une unite systemd individuelle.

## Commandes quotidiennes

Afficher l'etat :

```bash
bin/tansa-status
```

Voir les logs :

```bash
bin/tansa-logs
```

Redemarrer proprement :

```bash
bin/tansa-restart
```

Arreter :

```bash
bin/tansa-stop
```

Ces scripts utilisent `systemctl --user` et ne lancent jamais une seconde
instance de `bin/dev`.

## Demarrage manuel

Ne jamais lancer `bin/dev` manuellement lorsque `tansa-dev.service` est actif.

`bin/dev` prend un verrou exclusif dans :

```text
~/.local/state/tansa/tansa-dev.lock
```

Ce verrou empeche deux generations Tansa concurrentes.

## Service systemd

Installer ou mettre a jour l'unite :

```bash
mkdir -p ~/.config/systemd/user
cp ops/systemd/tansa-dev.service ~/.config/systemd/user/tansa-dev.service
systemctl --user daemon-reload
systemctl --user enable tansa-dev.service
systemctl --user start tansa-dev.service
```

Verifier :

```bash
systemctl --user status tansa-dev.service --no-pager
journalctl --user -u tansa-dev.service -n 200 --no-pager
```

## Reboot et linger

Pour demarrer Tansa apres un reboot sans session graphique ouverte, le linger
utilisateur doit etre actif :

```bash
loginctl show-user victor -p Linger
```

Si le resultat est `Linger=no`, Victor doit activer explicitement :

```bash
sudo loginctl enable-linger victor
```

Ne pas executer cette commande automatiquement depuis Codex.

## Migration depuis d'anciennes generations

Avant de demarrer `tansa-dev.service`, arreter proprement toute generation
ancienne :

1. `TSTP` pour empecher la prise de nouveaux jobs.
2. Attendre les frontieres atomiques des jobs actifs.
3. `TERM` pour arreter proprement.
4. Stopper et desactiver les units individuelles `tansa-*`.
5. Verifier avec `bin/tansa-status` qu'il ne reste aucun doublon.

Ne pas utiliser `kill -9` sauf dernier recours documente.
