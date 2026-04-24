Depuis la racine de Bitcoin Monitor :

# 1. Ajouter le fichier dans SUMMARY.md

Édite :

```text
docs/book/src/SUMMARY.md
```

Ajoute :

```markdown
- [Cluster](cluster.md)
```

Par exemple :

```markdown
# Summary

- [Introduction](introduction.md)
- [BTC](btc.md)
- [Exchange Like](exchange-like.md)
- [Cluster](cluster.md)
```

---

# 2. Créer le fichier

```bash
touch docs/book/src/cluster.md
```

Puis colle le chapitre dedans.

---

# 3. Générer le livre

```bash
cd docs/book
mdbook build
cd ../..
```

---

# 4. Commit

```bash
git add docs/book
git commit -m "Add cluster chapter"
git push
```

---

# 5. Republier GitHub Pages

```bash
git subtree push --prefix docs/book/book origin gh-pages
```

---

# 6. Vérifier en ligne

Ton chapitre sera ensuite disponible sur :

```text
https://svcrobotics.github.io/bitcoin_monitor/cluster.html
```

Et automatiquement visible dans la sidebar du livre.