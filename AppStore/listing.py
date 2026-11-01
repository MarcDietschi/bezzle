#!/usr/bin/env python3
"""The App Store listing in English, German, French and Italian. Writes metadata.json beside it after
checking Apple's limits, and that no text uses a dash as punctuation."""
import json, os, re, sys

SITE = "https://mfrports.github.io/bezzle-web"
NB = " "  # French puts a narrow space before : ; ! ?

L = {}

L["en-US"] = dict(
    name="Bezzle: UI & Graphic Design",
    subtitle="Every pro tool, for everyone",
    promotionalText="Bezzle is free. Not a trial, not freemium: components, prototypes, hand-off, live co-editing and every export, with no subscription and no account. Just design.",
    keywords="prototype,mockup,wireframe,vector,ui kit,icons,social media,carousel,poster,web,logo,flyer,cutout,ux",
    description="""Bezzle is a complete design studio for your Mac, and it is free. Not a trial, not freemium: no subscription, no account, no feature held back. Every tool and every export is yours from the first launch.

It brings together the best ideas of the design apps you know, from artboards and components to prototypes and co-editing, and makes each one simpler. Then it adds what none of them have: layouts that compose themselves for every size, dark mode in one click, decks for social media, one-click cutouts and an AI assistant that designs with you.

OPEN WHAT YOU ALREADY HAVE
• Opens Adobe XD, Figma (.fig) and Sketch files with artboards, layers, masks, text, pictures and layout grids.
• Brings any website in as layers you can edit, at desktop, tablet and phone widths.

DESIGN ANYTHING
• Apps, websites, social posts, slides and print on artboards for every device, side by side at true scale.
• Pen, knife, shape builder, booleans, masks and corners you round by dragging them, right on the canvas.
• Several fills, borders and shadows per layer, gradients, blurs, and pictures in shapes, borders and even letters.
• Mixed styles in one text, text that follows any curve, rulers, guides and layout grids.

COMPONENTS AND STYLES
• Every copy is the component. Change one and all follow, while each keeps its own words and photos. With variants.
• Give a color, a text style, a shadow or corners a name and use it everywhere. Take components and styles from your other designs.
• UI kits for iOS, macOS, Android and Bezzle, and thousands of Lucide, Phosphor and Material icons.

EVERY SIZE, LIGHT AND DARK
• Drag an artboard to a new size and Bezzle composes the layout again, with the design in mind.
• One click gives an artboard its dark look, drawn from your colors. Fine-tune any of them by hand.

PROTOTYPES AND HAND-OFF
• Link a button to a screen. The motion comes from your layout, and the prototype plays in a real device.
• Inspect shows developers every distance, color and font, with CSS and SwiftUI for each layer and assets to drag out.

DECKS, GRIDS AND PHOTOS
• Keep dozens of social posts on one artboard as a deck. Carousels for Instagram, LinkedIn and TikTok.
• Repeat grids turn one card into a list. Drop in a folder of photos or a spreadsheet and every cell fills itself.
• Remove the background of people, pets and products in one click, hair and all, and develop photos right in the design.
• Turn any layer in 3D by hand, in true perspective.

DESIGN TOGETHER
• Share over iCloud with anyone who has a Mac, no account needed. See everyone's pencil live as they work.
• Edits merge property by property, so nothing is ever overwritten. Talk it over in margin notes and go back to any version.

YOUR AI CAN DESIGN, TOO
• A built-in MCP server lets Claude or any MCP assistant build screens, decks and prototypes, and write changes back from code. Every step is in Undo.

EXPORT
• PNG, JPEG, WebP, AVIF, SVG and PDF from 1x to 4x, with export presets and every post of a deck at once.

MADE FOR THE MAC
• Native and fast, with tabs, light and dark mode, and designs that save themselves.
• Your designs stay on your Mac or in your own iCloud, and live sessions are end-to-end encrypted. No tracking, no ads.

Free, with everything included. Just design.""",
)

L["de-DE"] = dict(
    name="Bezzle: UI- & Grafikdesign",
    subtitle="Jedes Profi-Werkzeug für alle",
    promotionalText="Bezzle ist kostenlos. Keine Testversion, kein Freemium: Komponenten, Prototypen, Übergabe, Live-Zusammenarbeit und alle Exporte, ohne Abo und ohne Konto.",
    keywords="prototyp,mockup,wireframe,vektor,ui kit,icons,social media,karussell,poster,web,logo,freistellen",
    description="""Bezzle ist ein komplettes Designstudio für deinen Mac, und es ist kostenlos. Keine Testversion, kein Freemium: kein Abo, kein Konto, keine zurückgehaltene Funktion. Alle Werkzeuge und alle Exporte gehören dir vom ersten Start an.

Bezzle vereint die besten Ideen der Design-Apps, die du kennst, von Zeichenflächen und Komponenten bis zu Prototypen und gemeinsamem Arbeiten, und macht jede davon einfacher. Dazu kommt, was keine von ihnen hat: Layouts, die sich für jede Größe neu komponieren, Dunkelmodus mit einem Klick, Stapel für Social Media, Freistellen mit einem Klick und ein KI-Assistent, der mitgestaltet.

ÖFFNE, WAS DU SCHON HAST
• Öffnet Dateien aus Adobe XD, Figma (.fig) und Sketch, mit Zeichenflächen, Ebenen, Masken, Texten, Bildern und Layoutrastern.
• Holt jede Website als bearbeitbare Ebenen herein, in Desktop-, Tablet- und Smartphone-Breite.

GESTALTE ALLES
• Apps, Websites, Social Posts, Präsentationen und Print auf Zeichenflächen für jedes Gerät, nebeneinander im echten Maßstab.
• Zeichenstift, Messer, Formgenerator, boolesche Operationen, Masken und Ecken, die du direkt auf der Arbeitsfläche rund ziehst.
• Mehrere Füllungen, Konturen und Schatten pro Ebene, Verläufe, Unschärfen und Bilder in Formen, Konturen und sogar Buchstaben.
• Gemischte Stile in einem Text, Text auf beliebigen Kurven, Lineale, Hilfslinien und Layoutraster.

KOMPONENTEN UND STILE
• Jede Kopie ist die Komponente. Ändere eine, und alle folgen, jede mit eigenen Texten und Fotos. Mit Varianten.
• Gib einer Farbe, einem Textstil, einem Schatten oder Ecken einen Namen und nutze ihn überall. Übernimm Komponenten und Stile aus deinen anderen Designs.
• UI-Kits für iOS, macOS, Android und Bezzle, dazu Tausende Icons von Lucide, Phosphor und Material.

JEDE GRÖSSE, HELL UND DUNKEL
• Zieh eine Zeichenfläche auf eine neue Größe, und Bezzle komponiert das Layout neu, mit Blick auf das Design.
• Ein Klick gibt einer Zeichenfläche ihren dunklen Look, abgeleitet aus deinen Farben. Jede davon kannst du von Hand anpassen.

PROTOTYPEN UND ÜBERGABE
• Verbinde einen Button mit einem Screen. Die Bewegung ergibt sich aus deinem Layout, und der Prototyp läuft in einem echten Gerät.
• Untersuchen zeigt der Entwicklung jeden Abstand, jede Farbe und Schrift, mit CSS und SwiftUI für jede Ebene und Assets zum Herausziehen.

STAPEL, RASTER UND FOTOS
• Dutzende Social Posts auf einer Zeichenfläche als Stapel. Karussells für Instagram, LinkedIn und TikTok.
• Wiederholraster machen aus einer Karte eine Liste. Zieh einen Ordner mit Fotos oder eine Tabelle hinein, und jede Zelle füllt sich.
• Stelle Menschen, Tiere und Produkte mit einem Klick frei, samt Haaren, und entwickle Fotos direkt im Design.
• Dreh jede Ebene von Hand in 3D, in echter Perspektive.

GEMEINSAM GESTALTEN
• Teile über iCloud mit allen, die einen Mac haben, ohne Konto. Sieh live den Stift aller, während sie arbeiten.
• Änderungen werden Eigenschaft für Eigenschaft zusammengeführt, nichts wird überschrieben. Besprecht euch in Randnotizen und geh zu jeder Version zurück.

DEINE KI GESTALTET MIT
• Ein eingebauter MCP-Server lässt Claude oder einen anderen MCP-Assistenten Screens, Stapel und Prototypen bauen und Änderungen aus dem Code zurückschreiben. Jeder Schritt lässt sich widerrufen.

EXPORT
• PNG, JPEG, WebP, AVIF, SVG und PDF in 1x bis 4x, mit Export-Vorlagen und allen Posts eines Stapels auf einmal.

GEMACHT FÜR DEN MAC
• Nativ und schnell, mit Tabs, hell und dunkel, und Designs, die sich selbst sichern.
• Deine Designs bleiben auf deinem Mac oder in deiner eigenen iCloud, und Live-Sitzungen sind Ende-zu-Ende-verschlüsselt. Kein Tracking, keine Werbung.

Kostenlos, mit allem drin. Einfach gestalten.""",
)

L["fr-FR"] = dict(
    name="Bezzle : Design UI & graphique",
    subtitle="Tous les outils pro, pour tous",
    promotionalText=f"Bezzle est gratuit. Ni version d’essai ni freemium{NB}: composants, prototypes, inspection, création à plusieurs en direct et tous les exports, sans abonnement ni compte.",
    keywords="prototype,maquette,wireframe,vectoriel,kit ui,icônes,réseaux sociaux,carrousel,affiche,détourage",
    description=f"""Bezzle est un studio de design complet pour ton Mac, et il est gratuit. Ni version d’essai ni freemium{NB}: pas d’abonnement, pas de compte, aucune fonction réservée. Tous les outils et tous les exports sont à toi dès le premier lancement.

Bezzle réunit les meilleures idées des apps de design que tu connais, des plans de travail et composants aux prototypes et à la création à plusieurs, et rend chacune plus simple. Puis il ajoute ce qu’aucune n’a{NB}: des mises en page qui se recomposent pour chaque taille, le mode sombre en un clic, des piles pour les réseaux sociaux, le détourage en un clic et un assistant IA qui crée avec toi.

OUVRE CE QUE TU AS DÉJÀ
• Ouvre les fichiers Adobe XD, Figma (.fig) et Sketch avec plans de travail, calques, masques, textes, images et grilles de mise en page.
• Importe n’importe quel site web en calques modifiables, en largeur bureau, tablette et téléphone.

CRÉE TOUT CE QUE TU VEUX
• Apps, sites web, posts, présentations et print sur des plans de travail pour chaque appareil, côte à côte à l’échelle réelle.
• Plume, cutter, générateur de formes, opérations booléennes, masques et coins que tu arrondis en les tirant, sur la toile.
• Plusieurs remplissages, contours et ombres par calque, dégradés, flous et images dans les formes, les contours et même les lettres.
• Plusieurs styles dans un même texte, du texte qui suit n’importe quelle courbe, règles, repères et grilles.

COMPOSANTS ET STYLES
• Chaque copie est le composant. Modifie-en une et toutes suivent, chacune avec ses textes et ses photos. Avec variantes.
• Donne un nom à une couleur, un style de texte, une ombre ou des coins et utilise-le partout. Reprends composants et styles de tes autres designs.
• Des kits UI pour iOS, macOS, Android et Bezzle, et des milliers d’icônes Lucide, Phosphor et Material.

TOUTES LES TAILLES, CLAIR ET SOMBRE
• Donne une nouvelle taille à un plan de travail et Bezzle recompose la mise en page, en respectant le design.
• Un clic donne à un plan de travail sa version sombre, tirée de tes couleurs. Ajuste chacune à la main si tu veux.

PROTOTYPES ET INSPECTION
• Relie un bouton à un écran. L’animation découle de ta mise en page, et le prototype se joue dans un vrai appareil.
• Inspecter montre aux développeurs chaque distance, couleur et police, avec CSS et SwiftUI pour chaque calque et des assets à glisser.

PILES, GRILLES ET PHOTOS
• Des dizaines de posts sur un seul plan de travail, en pile. Des carrousels pour Instagram, LinkedIn et TikTok.
• Les grilles de répétition font d’une carte une liste. Glisse un dossier de photos ou un tableur et chaque cellule se remplit.
• Détoure personnes, animaux et produits en un clic, cheveux compris, et développe tes photos directement dans le design.
• Fais pivoter n’importe quel calque en 3D à la main, en vraie perspective.

CRÉER ENSEMBLE
• Partage via iCloud avec toute personne qui a un Mac, sans compte. Vois le crayon de chacun en direct pendant qu’il travaille.
• Les modifications se fusionnent propriété par propriété, rien n’est jamais écrasé. Discutez dans des notes en marge et reviens à n’importe quelle version.

TON IA CRÉE AVEC TOI
• Un serveur MCP intégré permet à Claude ou à tout assistant MCP de construire écrans, piles et prototypes, et de reporter les changements faits dans le code. Chaque étape peut être annulée.

EXPORT
• PNG, JPEG, WebP, AVIF, SVG et PDF de 1x à 4x, avec des préréglages d’export et tous les posts d’une pile d’un coup.

FAIT POUR LE MAC
• Natif et rapide, avec onglets, en clair comme en sombre, et des designs qui s’enregistrent tout seuls.
• Tes designs restent sur ton Mac ou dans ton propre iCloud, et les sessions en direct sont chiffrées de bout en bout. Aucun pistage, aucune pub.

Gratuit, tout compris. Il ne reste qu’à créer.""",
)

L["it"] = dict(
    name="Bezzle: Design UI e grafica",
    subtitle="Ogni strumento pro, per tutti",
    promotionalText="Bezzle è gratis. Non è una prova né un freemium: componenti, prototipi, ispezione, lavoro di squadra dal vivo e tutti gli export, senza abbonamento e senza account.",
    keywords="prototipo,mockup,wireframe,vettoriale,ui kit,icone,social media,carosello,poster,logo,scontorno",
    description="""Bezzle è uno studio di design completo per il tuo Mac, ed è gratis. Non è una prova né un freemium: niente abbonamento, niente account, nessuna funzione riservata. Tutti gli strumenti e tutti gli export sono tuoi dal primo avvio.

Bezzle riunisce le idee migliori delle app di design che conosci, dalle tavole e dai componenti ai prototipi e al lavoro di squadra, e rende ognuna più semplice. Poi aggiunge ciò che nessuna ha: layout che si ricompongono per ogni formato, modalità scura con un clic, pile per i social, scontorno con un clic e un assistente IA che progetta con te.

APRI CIÒ CHE HAI GIÀ
• Apre file Adobe XD, Figma (.fig) e Sketch, con tavole, livelli, maschere, testi, immagini e griglie di layout.
• Importa qualsiasi sito web come livelli modificabili, in larghezza desktop, tablet e smartphone.

PROGETTA DI TUTTO
• App, siti web, post, presentazioni e stampa su tavole per ogni dispositivo, una accanto all’altra in scala reale.
• Penna, taglierino, generatore di forme, operazioni booleane, maschere e angoli che arrotondi trascinandoli, sulla tela.
• Più riempimenti, bordi e ombre per livello, sfumature, sfocature e immagini in forme, bordi e perfino lettere.
• Stili diversi nello stesso testo, testo che segue qualsiasi curva, righelli, guide e griglie di layout.

COMPONENTI E STILI
• Ogni copia è il componente. Ne cambi una e tutte seguono, ognuna con i suoi testi e le sue foto. Con varianti.
• Dai un nome a un colore, uno stile di testo, un’ombra o degli angoli e usalo ovunque. Prendi componenti e stili dai tuoi altri design.
• UI kit per iOS, macOS, Android e Bezzle, e migliaia di icone Lucide, Phosphor e Material.

OGNI FORMATO, CHIARO E SCURO
• Porta una tavola a una nuova misura e Bezzle ricompone il layout, con il design in mente.
• Un clic dà a una tavola la sua versione scura, ricavata dai tuoi colori. Puoi ritoccarli tutti a mano.

PROTOTIPI E HAND-OFF
• Collega un pulsante a una schermata. Il movimento nasce dal layout, e il prototipo si riproduce in un vero dispositivo.
• Ispeziona mostra a chi sviluppa ogni distanza, colore e font, con CSS e SwiftUI per ogni livello e asset da trascinare fuori.

PILE, GRIGLIE E FOTO
• Decine di post social su un’unica tavola, in una pila. Caroselli per Instagram, LinkedIn e TikTok.
• Le griglie ripetute fanno di una scheda una lista. Trascinaci una cartella di foto o un foglio di calcolo e ogni cella si riempie.
• Scontorna persone, animali e prodotti con un clic, capelli compresi, e sviluppa le foto direttamente nel design.
• Ruota qualsiasi livello in 3D a mano, in vera prospettiva.

PROGETTARE INSIEME
• Condividi via iCloud con chiunque abbia un Mac, senza account. Guarda dal vivo la matita di ognuno mentre lavora.
• Le modifiche si uniscono proprietà per proprietà, nulla viene sovrascritto. Parlatene nelle note a margine e torna a qualsiasi versione.

LA TUA IA PROGETTA CON TE
• Un server MCP integrato permette a Claude o a qualsiasi assistente MCP di creare schermate, pile e prototipi, e di riportare le modifiche fatte nel codice. Ogni passo si può annullare.

EXPORT
• PNG, JPEG, WebP, AVIF, SVG e PDF da 1x a 4x, con preset di export e tutti i post di una pila in una volta.

FATTO PER IL MAC
• Nativo e veloce, con schede, chiaro e scuro, e design che si salvano da soli.
• I tuoi design restano sul tuo Mac o nel tuo iCloud, e le sessioni dal vivo sono cifrate end-to-end. Nessun tracciamento, nessuna pubblicità.

Gratis, tutto incluso. Non resta che progettare.""",
)

PAGES = {"en-US": "", "de-DE": "de/", "fr-FR": "fr/", "it": "it/"}
for loc, v in L.items():
    v["supportUrl"] = f"{SITE}/{PAGES[loc]}support.html"
    v["marketingUrl"] = f"{SITE}/{PAGES[loc]}"
    v["privacyPolicyUrl"] = f"{SITE}/{PAGES[loc]}privacy.html"

LIMITS = {"name": 30, "subtitle": 30, "promotionalText": 170, "description": 4000}
problems = []
for loc, v in L.items():
    for k, n in LIMITS.items():
        if len(v[k]) > n:
            problems.append(f"{loc} {k}: {len(v[k])} > {n}")
    if len(v["keywords"].encode()) > 100:
        problems.append(f"{loc} keywords: {len(v['keywords'].encode())} bytes > 100")
    for k, text in v.items():
        if "—" in text or re.search(r"\s–\s", text) or re.search(r"\s-\s", text):
            problems.append(f"{loc} {k}: dash used as punctuation")
if problems:
    sys.exit("\n".join(problems))

meta = {
    "app": {
        "bundleId": "com.erik.Bezzle", "sku": "com.erik.Bezzle", "primaryLocale": "en-US",
        "primaryCategory": "GRAPHICS_AND_DESIGN", "secondaryCategory": "PRODUCTIVITY",
        "price": {"baseTerritory": "USA", "customerPrice": "0.0"},
        "copyright": "2026 Erik Muffler",
        "contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT",
        "ageRating": "4+, no objectionable content",
        "privacy": "Data Not Collected",
    },
    "localizations": L,
    "review": {"notes": (
        "Bezzle is a free design app (UI, social posts, print). No account or sign-in is needed, and there are no in-app purchases.\n\n"
        "To try it: on the home screen pick a size (for example Phone) to start a design. Draw with the tools on the left "
        "(rectangle R, ellipse E, pen P, knife K, text T); the inspector on the right changes the selection. Select a shape and "
        "use + Repeat for a repeat grid, + 3D to turn it in depth. Drop a photo onto a rectangle, then choose Subject alone in "
        "the inspector (or Object > Remove Background) to cut out its subject on device with the Vision framework. "
        "File > Import from XD, Figma or Sketch opens design files from those apps.\n\n"
        "Sharing uses CloudKit: Share... invites others through the system share sheet; their changes merge into the design. "
        "While several people have a shared design open, the app also connects to a relay at bezzle-live.bezzle-live.workers.dev "
        "(Cloudflare) over a WebSocket, so that they see each other's pointers and changes at once. Everything sent there is "
        "end-to-end encrypted with a key that only the people in the share have. Nothing is sent anywhere else. The app collects no data.\n\n"
        "Why the app has com.apple.security.network.server: Bezzle runs a local MCP (Model Context Protocol) server so that "
        "AI assistants on the same Mac (Claude Desktop, Claude Code, Codex) can create and edit designs in the app. It is an "
        "HTTP server built with Network.framework (NWListener) that listens on 127.0.0.1 port 7412 and is limited to the "
        "loopback interface, so it never accepts connections from other computers; requests whose Host or Origin is not this "
        "Mac are refused. It starts with the app and can be turned off with Bezzle > Allow AI Control. "
        "Bezzle > Connect an AI Assistant connects an assistant to it. Without the entitlement the sandbox blocks the listener "
        "and this feature cannot work.\n\n"
        "To see the server answer, keep Bezzle open and run this in Terminal:\n"
        "curl -s http://127.0.0.1:7412/mcp -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}'\n"
        "It replies with the list of design tools an assistant can use.")},
}
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "metadata.json")
json.dump(meta, open(out, "w"), indent=1, ensure_ascii=False)
for loc, v in L.items():
    print(f"{loc}: name {len(v['name'])}, subtitle {len(v['subtitle'])}, promo {len(v['promotionalText'])}, keywords {len(v['keywords'].encode())}B, description {len(v['description'])}")
