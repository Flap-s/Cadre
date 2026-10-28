# Cadre

Outil de capture d'écran pour macOS 15+, inspiré des fonctionnalités de CleanShot X. Écrit de zéro en Swift
(AppKit + ScreenCaptureKit + SwiftUI pour les réglages), sans code, sons ni icônes repris de CleanShot X.

## Compiler et lancer

```bash
./Scripts/build-app.sh
```

```bash
open build.noindex/Cadre.app
```

L'app est signée ad hoc. Pour garder les autorisations macOS d'une compilation à l'autre, signez avec votre identité :
`CODESIGN_IDENTITY="Developer ID Application: …" ./Scripts/build-app.sh`. Copiez `build.noindex/Cadre.app` dans
`/Applications` pour l'option « Ouvrir au démarrage ».

Tests : `swift test`

## Fonctionnalités

| Fonction | Raccourci par défaut |
|---|---|
| All-In-One (sélection puis Capture / Pin / Texte / Défilement / Vidéo / GIF) | ⌥⇧5 |
| Capturer une zone (Espace = mode fenêtre, clic = fenêtre sous le curseur, Entrée = plein écran, ⇧ = carré) | ⌥⇧4 |
| Capturer le plein écran | ⌥⇧3 |
| Capturer une fenêtre (avec ou sans ombre) | ⌥⇧6 |
| Capturer la zone précédente | ⌥⇧7 |
| Retardateur (3 / 5 / 10 s) | ⌥⇧T |
| Capture défilante (manuelle ou auto-défilement) | ⌥⇧S |
| Capture de texte (OCR + QR codes) → presse-papiers | ⌥⇧O |
| Capturer et épingler | ⌥⇧P |
| Enregistrer l'écran (MP4) / GIF — re-appuyer pour arrêter | ⌥⇧R / ⌥⇧G |
| Masquer / afficher les icônes du bureau | ⌥⇧D |
| Historique des captures | ⌥⇧H |

- **Sélection** : loupe au pixel près, réticule, dimensions, gel de l'écran (option), multi-écrans.
- **Quick Access Overlay** : vignette flottante après chaque capture — Copier, Enregistrer, Annoter, Épingler,
  Partager, glisser-déposer vers n'importe quelle app, fermeture automatique configurable.
- **Éditeur d'annotations** : flèche, ligne, rectangle (vide/plein), ellipse, texte, crayon, surligneur, compteur
  numéroté, flou, pixellisation, projecteur, recadrage ; couleurs, 3 épaisseurs, annuler/rétablir, déplacer et
  supprimer, raccourcis clavier (A, R, O, T, P, H, N, B, X, S, C, V). Zoom net à toute taille (pincement,
  ⌘+ / ⌘− / ⌘0 ajuster / ⌘1 taille réelle) ; les captures défilantes s'ouvrent ajustées en largeur. Arrière-plan « beautify » : dégradés,
  marge, coins arrondis, ombre, ratio (1:1, 4:3, 16:9, 9:16).
- **Captures épinglées** : toujours au premier plan, zoom molette/pincement, opacité, verrouillage (clic au travers).
- **Enregistrement** : 30/60 fps, H.264 ou HEVC, son de l'ordinateur, micro, clics mis en évidence, curseur,
  webcam en bulle, frappes clavier à l'écran, compte à rebours, pause/reprise, redémarrer, annuler.
- **Éditeur vidéo** : découpe, suppression du son, export MP4 ou GIF.
- **Historique** : toutes les captures conservées (durée configurable), filtre, glisser-déposer, menu contextuel.
- **Automatisation** : schéma d'URL `cadre://capture-area`, `cadre://record-screen`, `cadre://all-in-one`,
  `cadre://open-annotate?filepath=/chemin/image.png`, `cadre://pin?filepath=…`, `cadre://open-settings`…

Non repris : l'hébergement cloud de CleanShot (service propriétaire) — le bouton Partager utilise le partage macOS.

## Mises à jour

Cadre vérifie les nouvelles versions publiées dans les **Releases** de ce dépôt GitHub : automatiquement
(au lancement puis toutes les 6 heures, désactivable) ou via **Réglages › Updates › Check Now** et le menu
« Check for Updates… ». Quand une version plus récente existe, **Download and Install** télécharge `Cadre.zip`,
vérifie l'app (identifiant `app.cadre.Cadre`, numéro de version, signature intacte), remplace l'app installée
puis la relance. Réglages, historique et autorisations macOS sont conservés.

L'app doit se trouver dans un dossier où tu peux écrire (par exemple `/Applications`).

### Publier une nouvelle version

1. Committer les changements.
2. Lancer (nécessite `gh auth login` une fois) :

```bash
./Scripts/release.sh 1.1.0 "Ce qui a changé"
```

Le script met à jour `VERSION`, lance les tests, compile, zippe l'app, crée le tag `v1.1.0`, pousse et publie
la release avec `Cadre.zip`. Les apps installées la proposent ensuite d'elles-mêmes.

## Autorisations macOS

- **Enregistrement de l'écran** (obligatoire) — demandée à la première capture.
- **Accessibilité** — seulement pour l'affichage des frappes clavier et l'auto-défilement.
- **Micro / Caméra** — seulement si activés dans Réglages › Recording.
