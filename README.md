# BandConnected

App iOS du projet PDG (HEIG-VD, groupe 9) : passerelle entre un bracelet ESP32-S3 en
BLE et l'API serveur de l'équipe.

## État

Réception BLE sur lien chiffré et appairé (code à 6 chiffres) : BPM, SpO2 et nombre de
pas, notifiés toutes les 4 s par le bracelet et affichés sur un écran unique. Pas
encore d'appel réseau ni de persistance.

Le contrat BLE (UUID, formats d'octets, appairage) est dans
[`CONNEXION-ESP32.md`](CONNEXION-ESP32.md) ; la version qui fait foi est
`../firmware/docs/ble-contract.md`.

## Build

```bash
xcodebuild -project BandConnected.xcodeproj -scheme BandConnected \
  -destination 'generic/platform=iOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

Le simulateur ne fait pas de Bluetooth, et il n'y a plus de source simulée : tout test
se fait sur iPhone physique (iOS 17.4+), bracelet allumé.

## Dépannage

### L'écran Debug

Bouton 🐞 en haut à droite de l'écran Mesures. Il montre les logs de la connection : la liste des caractéristiques découvertes, chaque trame reçue en hexadécimal,
les compteurs (paquets, débit, temps depuis la dernière trame) et les erreurs de
décodage. Le bouton **Exporter** en sort un `.txt` partageable.

### « Caractéristique inconnue » / tuiles bloquées sur `--`

**Symptôme.** L'app se connecte, l'appairage passe, des trames arrivent, mais il y a un problème de décodage.

**Cause : le cache GATT d'iOS.** Après un premier appairage, iOS mémorise sur disque la
table des services et caractéristiques du périphérique, pour ne pas refaire la découverte
à chaque connexion. Si le firmware change ensuite sa liste de caractéristiques (ajout,
retrait, renommage d'UUID), **iOS continue de servir l'ancienne table à l'app**. Il n'y a
aucune erreur : `didDiscoverCharacteristicsFor` renvoie simplement les anciens UUID.

Un vrai périphérique BLE peut forcer la purge en émettant une indication *Service
Changed*, mais tous les firmwares ne l'implémentent pas. Côté central, iOS n'expose
**aucune API** pour vider ce cache : la seule voie est manuelle.

**TODO** : on pourrai l'implémenter ? 

**Procédure**, dans cet ordre :

1. Fermer l'app complétement.
2. Réglages > Bluetooth > `BraceletTest` > ⓘ > **Oublier cet appareil**
3. **Redémarrer l'iPhone** — éventuellement
4. Relancer l'app, *Connecter*, saisir le code à 6 chiffres du moniteur série
