# Connexion ESP32-S3 ↔ app iOS — ce qu'il faut savoir

L'ESP32 notifie **BPM, SpO2 et nombre de pas toutes les 4 s**, sur trois caractéristiques
séparées, et imprime les mêmes valeurs sur son terminal série. Voir les deux côtés
afficher la même chose = la liaison BLE fonctionne de bout en bout.

Le lien est **chiffré et appairé** (Passkey Entry, code à 6 chiffres) : rien ne circule
tant que le code n'a pas été saisi sur le téléphone.

Rôles : l'**ESP32 est le périphérique** (il annonce, il attend), l'**iPhone est le
central** (il scanne, se connecte, s'abonne). L'ESP32 ne peut pas initier la connexion.

Le contrat qui fait foi est `../firmware/docs/ble-contract.md`. Ce document-ci décrit le
côté app.

---

## 1. Ce que l'app attend du firmware

| Point | Exigence |
|---|---|
| Advertising | l'ESP32 annonce en continu tant qu'il n'est pas connecté, et **réannonce à la déconnexion** |
| Reconnaissance | UUID de service `12345678-…-123456789abc` **annoncé** — c'est le filtre de scan |
| Nom | `BraceletTest` dans le scan response ; utile mais pas obligatoire (second critère) |
| Caractéristiques | `…ab1` BPM (1 o), `…ab2` SpO2 (1 o), `…ab3` pas (4 o **little-endian**), toutes en `NOTIFY` + `READ_ENC` |
| Appairage | le firmware réclame le chiffrement dès `onConnect` ; l'app affiche le prompt système |
| Cadence | 4 s. Rien ne casse si elle change, l'app affiche ce qui arrive |

⚠️ **Un UUID désynchronisé ne produit aucune erreur** : le scan reste simplement vide
pour toujours. C'est le premier truc à vérifier quand « rien n'arrive ».

⚠️ **Le nom voyage dans le scan response**, pas dans l'annonce : les 31 octets de
l'annonce sont déjà pris par les flags et l'UUID 128 bits. iOS scanne en actif, il le
reçoit — mais si le firmware oublie `NimBLEAdvertising::setName()`, la carte est vue
« sans nom ». D'où le filtrage sur l'UUID de service, qui lui est toujours annoncé.

⚠️ **`0` n'est pas une mesure.** Le capteur renvoie 0 quand il ne voit pas le poignet, et
le firmware ramène à 0 tout ce qui sort des plages physiologiques (sans quoi l'échec de
mesure de la lib DFRobot, `-1`, arriverait ici en **255 BPM**). L'app affiche `--`.

---

## 2. Ce qui doit être en place côté iPhone

- **iPhone physique obligatoire.** Le simulateur ne fait pas de Bluetooth :
  `CBCentralManager` y reste `.unsupported` et l'app affiche « Bluetooth indisponible ».
  Il n'y a plus de source mock : sans carte, il n'y a rien à voir.
- **Bluetooth activé** sur le téléphone.
- **Permission Bluetooth accordée** au premier lancement (la clé
  `NSBluetoothAlwaysUsageDescription` est déjà dans le projet).
- **Signature valable.** Team `JCC9V8ZU32` = Personal Team → l'app expire au bout de
  **7 jours**. Une démo se rebuild le matin même.
- App au **premier plan** : pas de Background Modes BLE, l'app en arrière-plan ne
  reçoit plus rien.

---

## 3. Procédure

1. Flasher et alimenter l'ESP32. Ouvrir le moniteur série pour voir les mesures.
2. Lancer l'app sur l'iPhone.
3. Taper **Connecter**.

Déroulé attendu du badge : gris *Déconnecté* → orange *Recherche…* → orange
*Connexion…* → orange *Appairage… saisis le code* → vert *Connecté à <nom> · chiffré*.
Le clavier iOS s'ouvre à l'étape d'appairage : taper le code à 6 chiffres imprimé par
le moniteur série de la carte (`123456` par défaut, défini dans
`../firmware/include/secrets.h`). Puis les tuiles se remplissent toutes les ~4 s.

Le bouton **Vider l'historique** efface ce qui est affiché (tuiles et courbe) sans
toucher à la connexion : les valeurs reviennent au cycle suivant.

⚠️ **Après un reflash de la carte** : Réglages iOS → Bluetooth → `BraceletTest` →
« Oublier cet appareil ». Les clés d'appairage sont régénérées à chaque flash, et un
téléphone qui garde les anciennes échoue sans message clair. iOS ne permet pas de
supprimer un appairage par programme — l'app ne peut qu'afficher la marche à suivre.

La reconnexion est automatique : si l'ESP32 s'éteint ou sort de portée, l'app se
remet à scanner toute seule et se reconnecte au retour.

---

## 4. Informations échangées

### ESP32 → iPhone

| Donnée | Quand | Contenu |
|---|---|---|
| Advertising | en continu avant connexion | nom annoncé + UUID de service + RSSI |
| Table GATT | à la connexion | services et caractéristiques avec leurs propriétés |
| BPM | toutes les 4 s | 1 octet `uint8`, 0 = pas de mesure |
| SpO2 | toutes les 4 s | 1 octet `uint8` (%), 0 = pas de mesure |
| Pas | toutes les 4 s | 4 octets `uint32` **little-endian**, cumul depuis le boot |

### iPhone → ESP32

| Donnée | Quand |
|---|---|
| Demande de connexion | au tap sur *Connecter*, sur le premier bracelet trouvé |
| Souscription aux notifications (CCCD) | juste après la découverte, pour chaque caractéristique `notify` |
| Lecture ponctuelle | une fois, sur chaque caractéristique `read`, **avant** la souscription — donne une valeur sans attendre le cycle suivant, et déclenche l'appairage si la carte ne l'a pas déjà réclamé |
| Réponse d'appairage (code à 6 chiffres) | à la connexion, saisie par l'utilisateur dans le prompt système |
| Lecture du RSSI | toutes les 2 s une fois connecté |

**Rien d'autre ne circule.** Pas d'écriture de commande, pas d'identifiant, pas
d'appel réseau : l'app ne parle à aucun serveur à ce stade.

### Ce que l'app en fait

Chemin : `BLEBraceletService` → `DebugLog` (journal `os.Logger`, sans écran) **et**
`VitalsDecoder` → `Reading` → `BraceletViewModel` → écran Mesures.

Une notification ne porte qu'**une** valeur : `VitalsDecoder` garde les deux autres en
mémoire et renvoie une mesure complète à chaque trame. Conséquence à connaître : entre
la première et la troisième notification d'un cycle, l'affichage mélange l'ancienne et
la nouvelle mesure. À 4 s de cadence, invisible.

---

## 5. Sécurité — ce qui est fait et ce qui ne l'est pas

Le lien est **chiffré, appairé et authentifié** : LE Secure Connections, Passkey Entry
(code à 6 chiffres), bonding. Le firmware réclame l'appairage dès la connexion et
refuse de notifier tant que le lien n'est pas chiffré.

Côté app, trois points à connaître :

- **L'état « chiffré » est déduit, pas lu.** iOS n'expose aucune API d'état de
  chiffrement sur `CBPeripheral`. La seule preuve accessible au central est indirecte :
  une lecture ou une notification qui aboutit sur une caractéristique `READ_ENC`. D'où
  l'état `.pairing` tant qu'aucune trame n'est arrivée, et `.connected` ensuite.
- **Le prompt de saisie appartient au système.** L'app ne dessine pas de clavier et ne
  manipule jamais le code : elle ne fait qu'expliquer où le lire.
- **On ne peut pas oublier un appairage par programme.** Après un reflash, seul
  l'utilisateur peut le faire depuis Réglages — l'app affiche le rappel en cas d'échec.

Limite connue, à mentionner dans le rapport : la passkey est compilée dans le firmware
(`include/secrets.h`, gitignoré) et imprimée sur son port série. Ça protège de l'écoute
passive et de l'homme du milieu, pas de quelqu'un qui a le binaire ou le câble USB.

---

## 6. Quand ça ne marche pas

| Symptôme | Cause probable | Correctif |
|---|---|---|
| Reste sur *Recherche…* | la carte n'annonce pas l'UUID `…abc` | côté firmware, vérifier `addServiceUUID` ; croiser avec nRF Connect |
| Connecté, mais aucune trame | la caractéristique n'a pas `notify`, ou le firmware n'appelle pas `notify()` | vérifier le dump GATT dans les logs Xcode (`subsystem == "nairod22.BandConnected"`) |
| Tuiles à `--` alors que le badge est vert | le capteur renvoie 0 (poignet absent, ou capteur pas câblé) | poser le capteur sur la peau ; comparer avec le moniteur série |
| Pas absurdes (millions) | steps relus en big-endian | l'app utilise `readUInt32LE` — vérifier qu'on n'a pas introduit un cast direct |
| Bloqué sur *Appairage…*, puis déconnexion | code annulé ou refusé — le firmware coupe le lien | relancer *Connecter* et saisir le code du moniteur série |
| Connexion refusée juste après un reflash | le téléphone garde d'anciennes clés de bonding | Réglages → Bluetooth → « Oublier cet appareil », puis reconnecter |
| « appairage requis ou refusé » dans le journal | lecture/souscription rejetée par la carte (lien non chiffré) | même correctif |
| Le GATT affiché ne correspond plus au firmware | cache GATT d'iOS | couper/rallumer le Bluetooth de l'iPhone |
| « Bluetooth indisponible (simulateur ?) » | app lancée dans le simulateur | passer sur iPhone physique |
| L'app ne se lance plus | signature Personal Team expirée (7 jours) | rebuild |
| Plus rien après une première déconnexion | le firmware n'a pas relancé l'advertising | corriger le callback `onDisconnect` |

**Croiser avec un tiers.** En cas de doute sur qui a tort, ouvrir **nRF Connect** ou
**LightBlue** sur les mêmes trames : si ces apps voient les octets et pas la nôtre, le
problème est côté iOS ; si elles ne voient rien non plus, il est côté firmware.
