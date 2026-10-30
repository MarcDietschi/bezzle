#!/usr/bin/env python3
"""Bezzle's website (mfrports.github.io/bezzle-app): the home page, Support and Privacy, in English,
German, French and Italian. Writes everything to public/, ready for GitHub Pages.
Pictures come from the App Store screenshots in ../screenshots."""
import html, os, re, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "public")
SHOTS = os.path.join(os.path.dirname(HERE), "screenshots")
ICON = os.path.join(os.path.dirname(os.path.dirname(HERE)), "Branding", "bezzle-icon.png")
STORE = "https://apps.apple.com/app/id6829008596"
ISSUES = "https://github.com/mfrports/bezzle-app/issues/new"
NB = " "
LANGS = [("en-US", "en", "", "EN"), ("de-DE", "de", "de/", "DE"), ("fr-FR", "fr", "fr/", "FR"), ("it", "it", "it/", "IT")]

T = {}
T["en"] = dict(
    title="Bezzle: the free design app for Mac",
    desc="Bezzle is a complete design studio for your Mac, and it is free: apps, websites, social posts and print, with repeat grids, decks, one-click cutouts, 3D and iCloud co-editing. No subscription, no account.",
    nav_support="Support", nav_privacy="Privacy",
    h1=("All the tools.", "None of the bills."),
    lede="Bezzle is a complete design studio for your Mac: apps, websites, social posts and print. It opens your Adobe XD, Figma and Sketch files, and it is free. Not a trial, not freemium.",
    cta="Get Bezzle on the Mac App Store", cta_small="Free · No subscription · No account · macOS 26 or later",
    free_h="Free. Really.", free_sub="Design tools have become rent. Bezzle is yours, with nothing held back.",
    free=[("No subscription", "Every tool and every export, from the first launch. No plans, no seats, no trial that runs out."),
          ("No account", "Open it and design. Sharing works through the iCloud your Mac already has."),
          ("Nothing locked", "No pro tier and no watermarks. What you see on this page is all of Bezzle, for everyone.")],
    best_h="The best of every design app. In one.",
    best_sub="The ideas designers love, each made simpler, and a few that no other app has.",
    cards=[("Open your files", "Adobe XD, Figma and Sketch files come in with artboards, layers, text, pictures, gradients and shadows."),
           ("Repeat grids", "Drag a handle and one card becomes a list. Drop in photos or a spreadsheet and every cell fills itself."),
           ("Decks for social media", "Dozens of posts on one artboard, stacked like cards. Restyle one and all follow."),
           ("Remove background", "People, pets and products lifted from their photo in one click, hair and all, right on your Mac."),
           ("3D by hand", "Grab a side and turn any layer in depth, in true perspective. No axes, no numbers."),
           ("Design together", "Share over iCloud with anyone who has a Mac. Changes merge, and no edit is ever overwritten."),
           ("Real vector tools", "Pen, knife, shape builder, boolean operations, squircle corners and corners you round by dragging."),
           ("Your AI designs, too", "A built-in MCP server lets Claude Desktop or any MCP assistant build and edit your designs, with every step in Undo."),
           ("Export everything", "PNG, JPEG, SVG and PDF from 1x to 4x: an artboard, a layer, or every post of a deck at once.")],
    gallery_h="See it at work",
    closing="Free, with everything included.",
    support_h="Support", support_sub="Help with Bezzle, the free design app for Mac",
    support_intro=f'Something not working, or an idea for Bezzle? <a href="{ISSUES}">Write to us</a> (a free GitHub account is needed). Every message is read. Please say what you did and what you expected.',
    faq_h="Questions",
    faq=[("Is Bezzle really free?", "Yes. Every feature is included, with no subscription, no in-app purchases and no account."),
         ("Can I open my Adobe XD, Figma or Sketch files?", "Yes. Choose File › Import from XD, Figma or Sketch, or drop the file on Bezzle. For Figma, first use Save local copy in Figma to get a .fig file. Artboards, layers, text, pictures, gradients and shadows come over; a short report lists anything that could not."),
         ("Where are my designs saved?", "In the Bezzle folder in your Documents. There is no Save command: a design is saved as you work, and the home screen shows all of them, latest first."),
         ("How do I work on a design with someone else?", "Click Share… in the design's window and invite them. They need a Mac signed in to iCloud, nothing else. Everyone's changes merge property by property, so nothing is overwritten."),
         ("How do I connect an AI assistant?", "Choose Bezzle › Connect an AI Assistant › Add to Claude Desktop. Other MCP clients can connect to http://127.0.0.1:7412/mcp on the same Mac. The server only listens on your Mac and can be turned off in the same menu."),
         ("How does Remove Background work?", "Select a layer filled with a photo and choose Subject alone in the inspector, or Object › Remove Background. It runs on your Mac with Apple's Vision framework. The original photo is kept, so you can restore it at any time."),
         ("What is a deck?", "One artboard that holds many posts, stacked like cards. Change how anything looks in one post and every post follows, while each keeps its own words and photos. Each post is exported as a file of its own."),
         ("Which Macs does Bezzle run on?", "Any Mac with macOS 26 or later.")],
    privacy_h="Privacy", effective="Effective 30 October 2026",
    privacy=[("", "Bezzle does not collect any data. It has no account, no analytics, no advertising and no tracking of any kind, and it sends nothing about you or your designs to us or to third parties."),
             ("Your designs", "Designs are files on your Mac, in the Bezzle folder in your Documents or wherever you keep them. Pictures you place are copied into the design. Remove Background runs on your Mac; photos are never uploaded."),
             ("Sharing over iCloud", "When you share a design, it is stored with Apple's iCloud (CloudKit) in your account and in the accounts of the people you invite. We cannot see it. Apple's privacy policy applies to iCloud."),
             ("AI assistants", "Bezzle includes a server for AI assistants that listens only on your Mac (127.0.0.1) and cannot be reached from the network. Nothing is shared with an assistant unless you connect one. If you do, what it reads from your design is handled by that assistant and its provider under their own privacy policy."),
             ("Network", "Bezzle makes no internet connections of its own other than iCloud, which it uses only for designs you share."),
             ("Crash reports", "If you have chosen to share analytics with app developers in macOS's settings, Apple may pass anonymous crash reports on to us. You can change this at any time in System Settings › Privacy & Security › Analytics & Improvements."),
             ("Children", "Bezzle collects no data from anyone, including children."),
             ("Changes and contact", f'If this policy changes, the new version will appear on this page with a new date. Questions are welcome: <a href="support.html">get in touch</a>.')],
)
T["de"] = dict(
    title="Bezzle: die kostenlose Design-App für den Mac",
    desc="Bezzle ist ein komplettes Designstudio für deinen Mac, und es ist kostenlos: Apps, Websites, Social Posts und Print, mit Wiederholrastern, Stapeln, Freistellen per Klick, 3D und gemeinsamem Arbeiten über iCloud. Kein Abo, kein Konto.",
    nav_support="Support", nav_privacy="Datenschutz",
    h1=("Alle Werkzeuge.", "Kein Abo."),
    lede="Bezzle ist ein komplettes Designstudio für deinen Mac: Apps, Websites, Social Posts und Print. Es öffnet deine Dateien aus Adobe XD, Figma und Sketch, und es ist kostenlos. Keine Testversion, kein Freemium.",
    cta="Bezzle im Mac App Store laden", cta_small="Kostenlos · Kein Abo · Kein Konto · macOS 26 oder neuer",
    free_h="Kostenlos. Wirklich.", free_sub="Design-Werkzeuge sind zur Miete geworden. Bezzle gehört dir, ohne Einschränkungen.",
    free=[("Kein Abo", "Alle Werkzeuge und alle Exporte vom ersten Start an. Keine Tarife, keine Lizenzen, keine ablaufende Testphase."),
          ("Kein Konto", "Öffnen und loslegen. Geteilt wird über die iCloud, die dein Mac schon hat."),
          ("Nichts gesperrt", "Keine Pro-Stufe, keine Wasserzeichen. Was du auf dieser Seite siehst, ist ganz Bezzle, für alle.")],
    best_h="Das Beste aller Design-Apps. In einer.",
    best_sub="Die Ideen, die Designer lieben, jede einfacher gemacht, und ein paar, die keine andere App hat.",
    cards=[("Öffne deine Dateien", "Dateien aus Adobe XD, Figma und Sketch kommen mit Zeichenflächen, Ebenen, Texten, Bildern, Verläufen und Schatten."),
           ("Wiederholraster", "Am Griff ziehen, und aus einer Karte wird eine Liste. Fotos oder eine Tabelle hineinziehen, und jede Zelle füllt sich."),
           ("Stapel für Social Media", "Dutzende Posts auf einer Zeichenfläche, gestapelt wie Karten. Ändere einen, und alle folgen."),
           ("Hintergrund entfernen", "Menschen, Tiere und Produkte mit einem Klick freigestellt, samt Haaren, direkt auf deinem Mac."),
           ("3D von Hand", "Eine Seite greifen und jede Ebene in die Tiefe drehen, in echter Perspektive. Keine Achsen, keine Zahlen."),
           ("Gemeinsam gestalten", "Über iCloud mit allen teilen, die einen Mac haben. Änderungen werden zusammengeführt, nichts wird überschrieben."),
           ("Echte Vektorwerkzeuge", "Zeichenstift, Messer, Formgenerator, boolesche Operationen, Squircle-Ecken und Ecken, die du rund ziehst."),
           ("Deine KI gestaltet mit", "Ein eingebauter MCP-Server lässt Claude Desktop oder jeden MCP-Assistenten deine Designs bauen und ändern, mit jedem Schritt im Widerrufen."),
           ("Alles exportieren", "PNG, JPEG, SVG und PDF in 1x bis 4x: eine Zeichenfläche, eine Ebene oder alle Posts eines Stapels auf einmal.")],
    gallery_h="So sieht es aus",
    closing="Kostenlos, mit allem drin.",
    support_h="Support", support_sub="Hilfe zu Bezzle, der kostenlosen Design-App für den Mac",
    support_intro=f'Funktioniert etwas nicht, oder hast du eine Idee für Bezzle? <a href="{ISSUES}">Schreib uns</a> (ein kostenloses GitHub-Konto ist nötig). Jede Nachricht wird gelesen. Bitte beschreib, was du getan und was du erwartet hast.',
    faq_h="Fragen",
    faq=[("Ist Bezzle wirklich kostenlos?", "Ja. Alle Funktionen sind enthalten, ohne Abo, ohne In-App-Käufe und ohne Konto."),
         ("Kann ich meine Dateien aus Adobe XD, Figma oder Sketch öffnen?", "Ja. Wähle Ablage › Aus XD, Figma oder Sketch importieren oder zieh die Datei auf Bezzle. Für Figma sicherst du die Datei zuerst in Figma mit Save local copy als .fig. Zeichenflächen, Ebenen, Texte, Bilder, Verläufe und Schatten kommen mit; ein kurzer Bericht nennt, was nicht übernommen werden konnte."),
         ("Wo werden meine Designs gespeichert?", "Im Ordner Bezzle in deinen Dokumenten. Einen Befehl zum Sichern gibt es nicht: Ein Design wird beim Arbeiten gesichert, und der Startbildschirm zeigt alle, die neuesten zuerst."),
         ("Wie arbeite ich mit jemandem zusammen an einem Design?", "Klick im Fenster des Designs auf Teilen … und lade die Person ein. Sie braucht nur einen Mac mit iCloud. Die Änderungen aller werden Eigenschaft für Eigenschaft zusammengeführt, nichts wird überschrieben."),
         ("Wie verbinde ich einen KI-Assistenten?", "Wähle Bezzle › KI-Assistenten verbinden › Zu Claude Desktop hinzufügen. Andere MCP-Clients verbinden sich auf demselben Mac mit http://127.0.0.1:7412/mcp. Der Server ist nur auf deinem Mac erreichbar und lässt sich im selben Menü ausschalten."),
         ("Wie funktioniert Hintergrund entfernen?", "Wähle eine Ebene mit einem Foto und im Inspektor Nur Motiv, oder Objekt › Hintergrund entfernen. Das geschieht auf deinem Mac mit Apples Vision-Framework. Das Originalfoto bleibt erhalten und lässt sich jederzeit wiederherstellen."),
         ("Was ist ein Stapel?", "Eine Zeichenfläche mit vielen Posts, gestapelt wie Karten. Ändere das Aussehen in einem Post, und alle folgen, während jeder seine eigenen Texte und Fotos behält. Jeder Post wird als eigene Datei exportiert."),
         ("Auf welchen Macs läuft Bezzle?", "Auf jedem Mac mit macOS 26 oder neuer.")],
    privacy_h="Datenschutz", effective="Gültig ab 30. Oktober 2026",
    privacy=[("", "Bezzle sammelt keine Daten. Es gibt kein Konto, keine Analyse, keine Werbung und kein Tracking jeglicher Art, und es sendet nichts über dich oder deine Designs an uns oder an Dritte."),
             ("Deine Designs", "Designs sind Dateien auf deinem Mac, im Ordner Bezzle in deinen Dokumenten oder wo immer du sie ablegst. Platzierte Bilder werden in das Design kopiert. Hintergrund entfernen läuft auf deinem Mac; Fotos werden nie hochgeladen."),
             ("Teilen über iCloud", "Wenn du ein Design teilst, wird es bei Apples iCloud (CloudKit) in deinem Konto und in den Konten der eingeladenen Personen gespeichert. Wir können es nicht sehen. Für iCloud gilt Apples Datenschutzrichtlinie."),
             ("KI-Assistenten", "Bezzle enthält einen Server für KI-Assistenten, der nur auf deinem Mac (127.0.0.1) erreichbar ist und nicht aus dem Netzwerk. Mit einem Assistenten wird nichts geteilt, solange du keinen verbindest. Tust du es, behandeln dieser Assistent und sein Anbieter, was er aus deinem Design liest, nach ihrer eigenen Datenschutzrichtlinie."),
             ("Netzwerk", "Bezzle baut keine eigenen Internetverbindungen auf, ausser zu iCloud, und das nur für Designs, die du teilst."),
             ("Absturzberichte", "Wenn du in den macOS-Einstellungen zugestimmt hast, Analysedaten mit App-Entwicklern zu teilen, kann Apple uns anonyme Absturzberichte weitergeben. Das kannst du jederzeit unter Systemeinstellungen › Datenschutz & Sicherheit › Analyse & Verbesserungen ändern."),
             ("Kinder", "Bezzle sammelt von niemandem Daten, auch nicht von Kindern."),
             ("Änderungen und Kontakt", 'Ändert sich diese Erklärung, erscheint die neue Fassung mit neuem Datum auf dieser Seite. Fragen sind willkommen: <a href="support.html">schreib uns</a>.')],
)
T["fr"] = dict(
    title="Bezzle : l’app de design gratuite pour Mac",
    desc="Bezzle est un studio de design complet pour ton Mac, et il est gratuit : apps, sites web, posts et print, avec grilles de répétition, piles, détourage en un clic, 3D et création à plusieurs via iCloud. Sans abonnement, sans compte.",
    nav_support="Assistance", nav_privacy="Confidentialité",
    h1=("Tous les outils.", "Aucun abonnement."),
    lede="Bezzle est un studio de design complet pour ton Mac : apps, sites web, posts pour les réseaux et print. Il ouvre tes fichiers Adobe XD, Figma et Sketch, et il est gratuit. Ni version d’essai ni freemium.",
    cta="Obtenir Bezzle sur le Mac App Store", cta_small="Gratuit · Sans abonnement · Sans compte · macOS 26 ou ultérieur",
    free_h="Gratuit. Vraiment.", free_sub="Les outils de design se louent désormais. Bezzle est à toi, sans rien retenir.",
    free=[("Sans abonnement", "Tous les outils et tous les exports dès le premier lancement. Ni formules, ni licences, ni essai qui expire."),
          ("Sans compte", "Ouvre l’app et crée. Le partage passe par l’iCloud que ton Mac a déjà."),
          ("Rien de verrouillé", "Pas de version pro, pas de filigrane. Ce que tu vois sur cette page, c’est tout Bezzle, pour tout le monde.")],
    best_h="Le meilleur de chaque app de design. En une seule.",
    best_sub="Les idées que les designers aiment, chacune rendue plus simple, et quelques-unes qu’aucune autre app n’a.",
    cards=[("Ouvre tes fichiers", "Les fichiers Adobe XD, Figma et Sketch arrivent avec plans de travail, calques, textes, images, dégradés et ombres."),
           ("Grilles de répétition", "Tire une poignée et une carte devient une liste. Glisse des photos ou un tableur et chaque cellule se remplit."),
           ("Des piles pour les réseaux", "Des dizaines de posts sur un seul plan de travail, empilés comme des cartes. Change l’un, tous suivent."),
           ("Supprimer l’arrière-plan", "Personnes, animaux et produits détourés en un clic, cheveux compris, directement sur ton Mac."),
           ("La 3D à la main", f"Saisis un bord et fais pivoter n’importe quel calque en profondeur, en vraie perspective. Ni axes ni chiffres."),
           ("Créer à plusieurs", "Partage via iCloud avec toute personne qui a un Mac. Les modifications se fusionnent, rien n’est jamais écrasé."),
           ("De vrais outils vectoriels", "Plume, cutter, générateur de formes, opérations booléennes, coins squircle et coins que tu arrondis en tirant."),
           ("Ton IA crée avec toi", "Un serveur MCP intégré permet à Claude Desktop ou à tout assistant MCP de construire et modifier tes designs, chaque étape annulable."),
           ("Tout exporter", f"PNG, JPEG, SVG et PDF de 1x à 4x{NB}: un plan de travail, un calque ou tous les posts d’une pile d’un coup.")],
    gallery_h="Bezzle en action",
    closing="Gratuit, tout compris.",
    support_h="Assistance", support_sub="De l’aide pour Bezzle, l’app de design gratuite pour Mac",
    support_intro=f'Quelque chose ne marche pas, ou une idée pour Bezzle{NB}? <a href="{ISSUES}">Écris-nous</a> (un compte GitHub gratuit est nécessaire). Chaque message est lu. Dis-nous ce que tu as fait et ce que tu attendais.',
    faq_h="Questions",
    faq=[(f"Bezzle est-il vraiment gratuit{NB}?", "Oui. Toutes les fonctions sont incluses, sans abonnement, sans achat intégré et sans compte."),
         (f"Puis-je ouvrir mes fichiers Adobe XD, Figma ou Sketch{NB}?", "Oui. Choisis Fichier › Importer depuis XD, Figma ou Sketch, ou dépose le fichier sur Bezzle. Pour Figma, utilise d’abord Save local copy dans Figma pour obtenir un fichier .fig. Plans de travail, calques, textes, images, dégradés et ombres sont repris ; un court rapport liste ce qui n’a pas pu l’être."),
         (f"Où sont enregistrés mes designs{NB}?", "Dans le dossier Bezzle de tes Documents. Il n’y a pas de commande Enregistrer : un design s’enregistre pendant que tu travailles, et l’écran d’accueil les montre tous, du plus récent au plus ancien."),
         (f"Comment travailler à plusieurs sur un design{NB}?", "Clique sur Partager… dans la fenêtre du design et invite la personne. Il lui faut seulement un Mac connecté à iCloud. Les modifications de chacun se fusionnent propriété par propriété, rien n’est écrasé."),
         (f"Comment connecter un assistant IA{NB}?", "Choisis Bezzle › Connecter un assistant IA › Ajouter à Claude Desktop. Les autres clients MCP se connectent à http://127.0.0.1:7412/mcp sur le même Mac. Le serveur n’écoute que sur ton Mac et se désactive dans le même menu."),
         (f"Comment fonctionne la suppression de l’arrière-plan{NB}?", "Sélectionne un calque rempli d’une photo et choisis Sujet seul dans l’inspecteur, ou Objet › Supprimer l’arrière-plan. Tout se fait sur ton Mac avec le framework Vision d’Apple. La photo d’origine est conservée et peut être rétablie à tout moment."),
         (f"Qu’est-ce qu’une pile{NB}?", "Un plan de travail qui contient plusieurs posts, empilés comme des cartes. Change l’apparence d’un élément dans un post et tous suivent, chacun gardant ses propres textes et photos. Chaque post est exporté dans son propre fichier."),
         (f"Sur quels Mac Bezzle fonctionne-t-il{NB}?", "Sur tout Mac avec macOS 26 ou ultérieur.")],
    privacy_h="Confidentialité", effective="En vigueur depuis le 30 octobre 2026",
    privacy=[("", "Bezzle ne collecte aucune donnée. Il n’a ni compte, ni statistiques, ni publicité, ni pistage d’aucune sorte, et n’envoie rien sur toi ou tes designs, ni à nous, ni à des tiers."),
             ("Tes designs", "Les designs sont des fichiers sur ton Mac, dans le dossier Bezzle de tes Documents ou là où tu les ranges. Les images placées sont copiées dans le design. La suppression de l’arrière-plan se fait sur ton Mac ; les photos ne sont jamais envoyées."),
             ("Partage via iCloud", "Quand tu partages un design, il est stocké dans iCloud (CloudKit) d’Apple, dans ton compte et dans ceux des personnes invitées. Nous ne pouvons pas le voir. La politique de confidentialité d’Apple s’applique à iCloud."),
             ("Assistants IA", "Bezzle inclut un serveur pour assistants IA qui n’écoute que sur ton Mac (127.0.0.1) et n’est pas joignable depuis le réseau. Rien n’est partagé avec un assistant tant que tu n’en connectes pas. Si tu le fais, ce qu’il lit de ton design est traité par cet assistant et son fournisseur selon leur propre politique de confidentialité."),
             ("Réseau", "Bezzle n’établit aucune connexion internet propre, sauf vers iCloud, et seulement pour les designs que tu partages."),
             ("Rapports de plantage", "Si tu as choisi de partager les données d’analyse avec les développeurs dans les réglages de macOS, Apple peut nous transmettre des rapports de plantage anonymes. Tu peux changer cela à tout moment dans Réglages Système › Confidentialité et sécurité › Analyse et améliorations."),
             ("Enfants", "Bezzle ne collecte de données de personne, enfants compris."),
             ("Modifications et contact", f'Si cette politique change, la nouvelle version paraîtra sur cette page avec une nouvelle date. Les questions sont les bienvenues{NB}: <a href="support.html">écris-nous</a>.')],
)
T["it"] = dict(
    title="Bezzle: l’app di design gratuita per Mac",
    desc="Bezzle è uno studio di design completo per il tuo Mac, ed è gratis: app, siti web, post social e stampa, con griglie ripetute, pile, scontorno con un clic, 3D e lavoro di squadra via iCloud. Niente abbonamento, niente account.",
    nav_support="Assistenza", nav_privacy="Privacy",
    h1=("Tutti gli strumenti.", "Nessun abbonamento."),
    lede="Bezzle è uno studio di design completo per il tuo Mac: app, siti web, post social e stampa. Apre i tuoi file Adobe XD, Figma e Sketch, ed è gratis. Non è una prova né un freemium.",
    cta="Scarica Bezzle dal Mac App Store", cta_small="Gratis · Nessun abbonamento · Nessun account · macOS 26 o successivo",
    free_h="Gratis. Davvero.", free_sub="Gli strumenti di design sono diventati un affitto. Bezzle è tuo, senza limiti.",
    free=[("Nessun abbonamento", "Tutti gli strumenti e tutti gli export dal primo avvio. Niente piani, niente licenze, nessuna prova che scade."),
          ("Nessun account", "Apri e progetta. La condivisione passa dall’iCloud che il tuo Mac ha già."),
          ("Niente di bloccato", "Nessuna versione pro, nessuna filigrana. Quello che vedi in questa pagina è tutto Bezzle, per tutti.")],
    best_h="Il meglio di ogni app di design. In una sola.",
    best_sub="Le idee che i designer amano, ognuna resa più semplice, e alcune che nessun’altra app ha.",
    cards=[("Apri i tuoi file", "I file Adobe XD, Figma e Sketch arrivano con tavole, livelli, testi, immagini, sfumature e ombre."),
           ("Griglie ripetute", "Trascina una maniglia e una scheda diventa una lista. Trascina foto o un foglio di calcolo e ogni cella si riempie."),
           ("Pile per i social", "Decine di post su un’unica tavola, impilati come carte. Ne cambi uno e tutti seguono."),
           ("Rimuovi sfondo", "Persone, animali e prodotti scontornati con un clic, capelli compresi, direttamente sul tuo Mac."),
           ("3D a mano", "Afferra un lato e ruota qualsiasi livello in profondità, in vera prospettiva. Niente assi, niente numeri."),
           ("Progettare insieme", "Condividi via iCloud con chiunque abbia un Mac. Le modifiche si uniscono, niente viene mai sovrascritto."),
           ("Veri strumenti vettoriali", "Penna, taglierino, generatore di forme, operazioni booleane, angoli squircle e angoli che arrotondi trascinando."),
           ("La tua IA progetta con te", "Un server MCP integrato permette a Claude Desktop o a qualsiasi assistente MCP di creare e modificare i tuoi design, ogni passo annullabile."),
           ("Esporta tutto", "PNG, JPEG, SVG e PDF da 1x a 4x: una tavola, un livello o tutti i post di una pila in una volta.")],
    gallery_h="Guardalo all’opera",
    closing="Gratis, tutto incluso.",
    support_h="Assistenza", support_sub="Aiuto per Bezzle, l’app di design gratuita per Mac",
    support_intro=f'Qualcosa non funziona, o hai un’idea per Bezzle? <a href="{ISSUES}">Scrivici</a> (serve un account GitHub gratuito). Leggiamo ogni messaggio. Indica cosa hai fatto e cosa ti aspettavi.',
    faq_h="Domande",
    faq=[("Bezzle è davvero gratis?", "Sì. Tutte le funzioni sono incluse, senza abbonamento, senza acquisti in-app e senza account."),
         ("Posso aprire i miei file Adobe XD, Figma o Sketch?", "Sì. Scegli Archivio › Importa da XD, Figma o Sketch, o trascina il file su Bezzle. Per Figma, usa prima Save local copy in Figma per ottenere un file .fig. Tavole, livelli, testi, immagini, sfumature e ombre vengono importati; un breve resoconto elenca ciò che non è stato possibile."),
         ("Dove vengono salvati i miei design?", "Nella cartella Bezzle dei tuoi Documenti. Non c’è un comando Salva: un design si salva mentre lavori, e la schermata iniziale li mostra tutti, dal più recente."),
         ("Come lavoro su un design con qualcun altro?", "Fai clic su Condividi… nella finestra del design e invita la persona. Le serve solo un Mac con iCloud. Le modifiche di tutti si uniscono proprietà per proprietà, niente viene sovrascritto."),
         ("Come collego un assistente IA?", "Scegli Bezzle › Collega un assistente IA › Aggiungi a Claude Desktop. Gli altri client MCP si collegano a http://127.0.0.1:7412/mcp sullo stesso Mac. Il server ascolta solo sul tuo Mac e si può disattivare dallo stesso menu."),
         ("Come funziona Rimuovi sfondo?", "Seleziona un livello riempito con una foto e scegli Solo soggetto nell’ispettore, oppure Oggetto › Rimuovi sfondo. Avviene sul tuo Mac con il framework Vision di Apple. La foto originale resta e puoi ripristinarla in qualsiasi momento."),
         ("Che cos’è una pila?", "Una tavola che contiene molti post, impilati come carte. Cambi l’aspetto di qualcosa in un post e tutti seguono, mentre ognuno tiene i suoi testi e le sue foto. Ogni post viene esportato in un file proprio."),
         ("Su quali Mac funziona Bezzle?", "Su qualsiasi Mac con macOS 26 o successivo.")],
    privacy_h="Privacy", effective="In vigore dal 30 ottobre 2026",
    privacy=[("", "Bezzle non raccoglie alcun dato. Non ha account, statistiche, pubblicità né tracciamento di alcun tipo, e non invia nulla su di te o sui tuoi design, né a noi né a terzi."),
             ("I tuoi design", "I design sono file sul tuo Mac, nella cartella Bezzle dei tuoi Documenti o dove li tieni. Le immagini inserite vengono copiate nel design. Rimuovi sfondo funziona sul tuo Mac; le foto non vengono mai caricate."),
             ("Condivisione via iCloud", "Quando condividi un design, viene conservato in iCloud (CloudKit) di Apple, nel tuo account e in quelli delle persone invitate. Noi non possiamo vederlo. Per iCloud vale l’informativa sulla privacy di Apple."),
             ("Assistenti IA", "Bezzle include un server per assistenti IA che ascolta solo sul tuo Mac (127.0.0.1) e non è raggiungibile dalla rete. Nulla viene condiviso con un assistente finché non ne colleghi uno. Se lo fai, ciò che legge dal tuo design è trattato da quell’assistente e dal suo fornitore secondo la loro informativa sulla privacy."),
             ("Rete", "Bezzle non apre connessioni internet proprie, se non verso iCloud e solo per i design che condividi."),
             ("Rapporti sugli arresti anomali", "Se nelle impostazioni di macOS hai scelto di condividere le analisi con gli sviluppatori, Apple può inoltrarci rapporti anonimi sugli arresti anomali. Puoi cambiarlo in qualsiasi momento in Impostazioni di Sistema › Privacy e sicurezza › Analisi e miglioramenti."),
             ("Bambini", "Bezzle non raccoglie dati da nessuno, bambini compresi."),
             ("Modifiche e contatti", 'Se questa informativa cambia, la nuova versione comparirà su questa pagina con una nuova data. Le domande sono benvenute: <a href="support.html">scrivici</a>.')],
)

MARK = '<svg class="mark" viewBox="0 0 300 24" preserveAspectRatio="none" aria-hidden="true"><path d="M3 15 C 70 8, 160 6, 297 10" stroke-width="6"/><path d="M28 20 C 110 15, 200 14, 282 16" stroke-width="3" opacity=".55"/></svg>'
DOT = '<svg class="dot" viewBox="0 0 22 22" aria-hidden="true"><rect x="1" y="1" width="20" height="20" rx="6" fill="var(--well)"/><rect x="6" y="6" width="10" height="10" rx="3.2" fill="var(--pencil)"/></svg>'


def page(lang, prefix, title, desc, body, here):
    up = "../" if prefix else ""
    switch = " ".join(
        f'<a href="{up}{p}{here}"{" aria-current=page" if l == lang else ""} hreflang="{l}">{label}</a>' for _, l, p, label in LANGS)
    alts = "".join(f'<link rel="alternate" hreflang="{l}" href="https://mfrports.github.io/bezzle-app/{p}{here}">' for _, l, p, _ in LANGS)
    t = T[lang]
    return f"""<!DOCTYPE html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<meta name="description" content="{html.escape(desc)}">
<meta property="og:title" content="{html.escape(title)}">
<meta property="og:description" content="{html.escape(desc)}">
<meta property="og:image" content="https://mfrports.github.io/bezzle-app/img/{LANGS[[x[1] for x in LANGS].index(lang)][0]}/1.jpg">
{alts}
<link rel="icon" href="{up}img/favicon.png">
<link rel="stylesheet" href="{up}style.css">
</head>
<body>
<div class="wrap">
  <header class="top">
    <a class="brand" href="./"><img src="{up}img/icon-256.png" alt="">Bezzle</a>
    <nav class="links"><a href="support.html">{t["nav_support"]}</a><a href="privacy.html">{t["nav_privacy"]}</a><span class="langs">{switch}</span></nav>
  </header>
{body}
</div>
<footer><div class="wrap"><span>© 2026 Erik Muffler</span><nav><a href="./">Bezzle</a><a href="support.html">{t["nav_support"]}</a><a href="privacy.html">{t["nav_privacy"]}</a></nav></div></footer>
</body>
</html>
"""


def e(s):
    return html.escape(s, quote=False)


def home(lang, locale, up):
    t = T[lang]
    img = f"{up}img/{locale}"
    free = "".join(f'<div class="card">{DOT}<h3>{e(h)}</h3><p>{e(p)}</p></div>' for h, p in t["free"])
    cards = "".join(f'<div class="card">{DOT}<h3>{e(h)}</h3><p>{e(p)}</p></div>' for h, p in t["cards"])
    shots = "".join(f'<figure><img src="{img}/{i}.jpg" width="1440" height="900" loading="lazy" alt=""></figure>' for i in (3, 4, 5, 6, 7, 8))
    a, b = t["h1"]
    return f"""  <div class="hero">
    <img class="icon" src="{up}img/icon-256.png" alt="">
    <h1>{e(a)}<br><span class="marked">{e(b)}{MARK}</span></h1>
    <p class="lede">{e(t["lede"])}</p>
    <div class="cta">
      <a class="button" href="{STORE}">{e(t["cta"])}</a>
      <small>{e(t["cta_small"])}</small>
    </div>
    <img class="window" src="{up}img/window.png" width="1600" height="1000" alt="">
  </div>
  <section>
    <h2>{e(t["free_h"])}</h2>
    <p class="sub">{e(t["free_sub"])}</p>
    <div class="grid">{free}</div>
  </section>
  <section>
    <h2>{e(t["best_h"])}</h2>
    <p class="sub">{e(t["best_sub"])}</p>
    <div class="grid">{cards}</div>
  </section>
  <section>
    <h2>{e(t["gallery_h"])}</h2>
    <div class="pair">{shots}</div>
  </section>
  <div class="closing">
    <h2>{e(t["closing"])}</h2>
    <a class="button" href="{STORE}">{e(t["cta"])}</a>
  </div>"""


def support(lang):
    t = T[lang]
    faq = "".join(f"<details><summary>{e(q)}</summary><p>{e(a)}</p></details>" for q, a in t["faq"])
    return f"""  <article class="narrow">
    <h1>{e(t["support_h"])}</h1>
    <p class="meta">{e(t["support_sub"])}</p>
    <p>{t["support_intro"]}</p>
    <h2>{e(t["faq_h"])}</h2>
    {faq}
  </article>"""


def privacy(lang):
    t = T[lang]
    parts = "".join((f"<h2>{e(h)}</h2>" if h else "") + f"<p>{p}</p>" for h, p in t["privacy"])
    return f"""  <article class="narrow">
    <h1>{e(t["privacy_h"])}</h1>
    <p class="meta">{e(t["effective"])}</p>
    {parts}
  </article>"""


def check():
    bad = []
    for lang, t in T.items():
        for k, v in t.items():
            for s in (v if isinstance(v, (list, tuple)) else [v]):
                for x in (s if isinstance(s, tuple) else [s]):
                    if "—" in x or re.search(r"\s[–-]\s", x):
                        bad.append(f"{lang} {k}: {x[:60]}")
    if bad:
        sys.exit("Dashes used as punctuation:\n" + "\n".join(bad))


def main():
    check()
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(os.path.join(OUT, "img"))
    shutil.copy(os.path.join(HERE, "style.css"), OUT)
    open(os.path.join(OUT, ".nojekyll"), "w").close()
    subprocess.run(["sips", "-Z", "256", ICON, "--out", os.path.join(OUT, "img", "icon-256.png")], check=True, capture_output=True)
    subprocess.run(["sips", "-Z", "64", ICON, "--out", os.path.join(OUT, "img", "favicon.png")], check=True, capture_output=True)
    subprocess.run(["sips", "-Z", "1600", os.path.join(os.path.dirname(HERE), "screenshots-src", "assets", "hero.png"),
                    "--out", os.path.join(OUT, "img", "window.png")], check=True, capture_output=True)
    for locale, lang, prefix, _ in LANGS:
        os.makedirs(os.path.join(OUT, "img", locale))
        for i in range(1, 9):
            subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "84", "-Z", "1440",
                            os.path.join(SHOTS, locale, f"{i}.png"), "--out", os.path.join(OUT, "img", locale, f"{i}.jpg")],
                           check=True, capture_output=True)
        folder = os.path.join(OUT, prefix)
        os.makedirs(folder, exist_ok=True)
        up = "../" if prefix else ""
        t = T[lang]
        open(os.path.join(folder, "index.html"), "w").write(page(lang, prefix, t["title"], t["desc"], home(lang, locale, up), ""))
        open(os.path.join(folder, "support.html"), "w").write(page(lang, prefix, f'{t["support_h"]} · Bezzle', t["support_sub"], support(lang), "support.html"))
        open(os.path.join(folder, "privacy.html"), "w").write(page(lang, prefix, f'{t["privacy_h"]} · Bezzle', t["privacy"][0][1], privacy(lang), "privacy.html"))
    open(os.path.join(OUT, "README.md"), "w").write(
        "# Bezzle\n\nThe website of [Bezzle](https://mfrports.github.io/bezzle-app/), the free design app for Mac: "
        "home page, support and privacy policy in English, German, French and Italian.\n\n"
        "To report a problem or suggest something, [open an issue](https://github.com/mfrports/bezzle-app/issues/new).\n")
    print("site written to", OUT)


if __name__ == "__main__":
    main()
