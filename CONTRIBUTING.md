# Contribuer

Merci de l'intérêt porté à ce dépôt.

## Proposer un changement

1. Forker le dépôt et créer une branche dédiée :
   - `feat/...` pour une nouvelle fonctionnalité
   - `fix/...` pour une correction
   - `docs/...` pour la documentation uniquement
2. Garder les scripts idempotents : relancer un script ne doit jamais corrompre une configuration
   existante (vérifier l'état avant d'agir, prévoir un retour arrière).
3. Ne jamais committer d'IP réelle, de nom d'hôte, d'identifiant de compte ou de secret — utiliser
   des variables d'environnement avec des valeurs d'exemple (voir les scripts existants sous
   [scripts/](scripts)).
4. Documenter toute nouvelle variable d'environnement dans l'en-tête du script concerné.
5. Ouvrir une Pull Request décrivant le changement, le contexte, et comment il a été testé.

## Attentes

- Scripts shell : `bash -n` doit passer sans erreur, `set -euo pipefail` en tête.
- Documentation : rester cohérent avec le style existant (français, sections courtes et actionnables).

Les Pull Requests sont revues avant fusion.
