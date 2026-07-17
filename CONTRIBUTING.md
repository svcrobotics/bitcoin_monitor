# Contribution à Tansa

## Avant chaque nouvelle fonctionnalité

Toute nouvelle fonctionnalité doit être développée dans une branche dédiée créée depuis la dernière version de `main`.

```bash
cd ~/bitcoin_monitor
git switch main
git pull --ff-only
git switch -c feature/nom-de-la-fonctionnalite
```

Remplacer `nom-de-la-fonctionnalite` par un nom court et descriptif, par exemple :

```bash
git switch -c feature/actor-label-statistics
```

Cette procédure maintient `main` stable. L’option `--ff-only` empêche Git de créer automatiquement une fusion si la branche locale et la branche distante ont divergé.

Les modifications, tests et commits de la fonctionnalité sont effectués sur la branche `feature/...`. La branche est intégrée dans `main` seulement après validation.
