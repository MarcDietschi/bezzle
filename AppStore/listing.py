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
    promotionalText="Bezzle is free. Not a trial, not freemium: every tool, every export and iCloud co-editing, with no subscription and no account. Just open it and design.",
    keywords="mockup,wireframe,vector,social media,carousel,poster,layout,artboard,ux,web,logo,icon,flyer,cutout",
    description="""Bezzle is a complete design studio for your Mac, and it is free. Not a trial, not freemium: no subscription, no account, no feature held back. Every tool and every export is yours from the first launch.

It brings together the best ideas of the design apps you know: artboards and repeat grids, smooth squircle corners, real vector tools, co-editing and the speed of a native Mac app. Each one is made simpler here. Then Bezzle adds what none of them have: decks for social media, one-click cutouts, 3D you turn by hand and an AI assistant that designs with you.

OPEN WHAT YOU ALREADY HAVE
• Opens Adobe XD, Figma (.fig) and Sketch files, with artboards, layers, text, pictures, gradients and shadows.
• A short report shows what came in, so nothing changes without you knowing.

APPS, WEBSITES, POSTS AND PRINT
• Artboards for phones, tablets, laptops, desktops, watches, social posts, stories and A4, side by side at true scale.
• Pen, knife, shape builder and boolean operations, and corners you round by dragging them, right on the canvas.
• Squircle corners, gradients you drag on the canvas, background blurs, blurs that ramp across a layer, and shadows inside and out.
• Pictures fill any shape. Double-click to move and scale them inside it.

REPEAT GRIDS
• Drag a handle and one card becomes a list or a gallery. Change any cell and every cell follows.
• Drop a folder of photos, a text file or a spreadsheet onto a grid, and each cell gets its own content.
• Sample names, cities, prices, dates and headlines let you judge a layout before the real content arrives.

DECKS FOR SOCIAL MEDIA
• Keep dozens of posts on one artboard, stacked like cards. Restyle one and all of them follow.
• Each post keeps its own words and photos. Spread the stack out to reorder, export or remove posts.
• Carousels for Instagram, LinkedIn and TikTok: one wide design, exported as one picture per slide.

REMOVE BACKGROUND
• One click lifts people, pets and products out of their photo, hair and all, right on your Mac.
• The shadow falls from the subject's real outline, and the original photo is always kept.

3D WITHOUT THE MATH
• Grab just outside a side and turn any layer in depth, in true perspective. No axes, no numbers.
• Or aim it with a small pad in the inspector. Exact degrees are there when you need them.

DESIGN TOGETHER
• Share a design over iCloud with anyone who has a Mac. Nobody has to create an account.
• Changes merge property by property, so several people can work at once and no edit is ever overwritten.

YOUR AI CAN DESIGN, TOO
• Bezzle has a built-in MCP server. Add it to Claude Desktop with one click, or connect any MCP assistant.
• The assistant builds screens, fills grids, makes decks, removes backgrounds and exports, and every step is in Undo.

EXPORT
• PNG, JPEG, SVG and PDF from 1x to 4x: one artboard, one layer, or every post of a deck at once.

MADE FOR THE MAC
• Native and fast, in light and dark, with designs that save themselves as you work.
• Your designs stay on your Mac or in your own iCloud. No tracking, no ads.

Free, with everything included. Just design.""",
)

L["de-DE"] = dict(
    name="Bezzle: UI- & Grafikdesign",
    subtitle="Jedes Profi-Werkzeug für alle",
    promotionalText="Bezzle ist kostenlos. Keine Testversion, kein Freemium: alle Werkzeuge, alle Exporte und gemeinsames Arbeiten über iCloud, ohne Abo und ohne Konto.",
    keywords="mockup,wireframe,vektor,social media,karussell,poster,layout,ux,web,logo,icon,flyer,freistellen",
    description="""Bezzle ist ein komplettes Designstudio für deinen Mac, und es ist kostenlos. Keine Testversion, kein Freemium: kein Abo, kein Konto, keine zurückgehaltene Funktion. Alle Werkzeuge und alle Exporte gehören dir vom ersten Start an.

Bezzle vereint die besten Ideen der Design-Apps, die du kennst: Zeichenflächen und Wiederholraster, weiche Squircle-Ecken, echte Vektorwerkzeuge, gemeinsames Arbeiten und das Tempo einer nativen Mac-App. Jedes davon ist hier einfacher. Dazu kommt, was keine von ihnen hat: Stapel für Social Media, Freistellen mit einem Klick, 3D, das du von Hand drehst, und ein KI-Assistent, der mitgestaltet.

ÖFFNE, WAS DU SCHON HAST
• Öffnet Dateien aus Adobe XD, Figma (.fig) und Sketch, mit Zeichenflächen, Ebenen, Texten, Bildern, Verläufen und Schatten.
• Ein kurzer Bericht zeigt, was übernommen wurde, damit sich nichts ohne dein Wissen ändert.

APPS, WEBSITES, POSTS UND PRINT
• Zeichenflächen für Smartphones, Tablets, Laptops, Desktops, Uhren, Social Posts, Storys und A4, nebeneinander im echten Maßstab.
• Zeichenstift, Messer, Formgenerator und boolesche Operationen, dazu Ecken, die du direkt auf der Arbeitsfläche rund ziehst.
• Squircle-Ecken, Verläufe, die du auf der Arbeitsfläche ziehst, Hintergrundunschärfe, Unschärfe mit Verlauf und Schatten innen wie außen.
• Bilder füllen jede Form. Ein Doppelklick, und du verschiebst und skalierst sie darin.

WIEDERHOLRASTER
• Am Griff ziehen, und aus einer Karte wird eine Liste oder Galerie. Ändere eine Zelle, und alle folgen.
• Zieh einen Ordner mit Fotos, eine Textdatei oder eine Tabelle auf ein Raster, und jede Zelle erhält ihren eigenen Inhalt.
• Beispielnamen, Städte, Preise, Daten und Titel zeigen dir das Layout, bevor die echten Inhalte da sind.

STAPEL FÜR SOCIAL MEDIA
• Dutzende Posts auf einer Zeichenfläche, gestapelt wie Karten. Ändere den Look von einem, und alle folgen.
• Jeder Post behält seine eigenen Texte und Fotos. Fächere den Stapel auf, um Posts zu ordnen, zu exportieren oder zu entfernen.
• Karussells für Instagram, LinkedIn und TikTok: ein breites Design, exportiert als ein Bild pro Slide.

HINTERGRUND ENTFERNEN
• Ein Klick stellt Menschen, Tiere und Produkte frei, samt Haaren, direkt auf deinem Mac.
• Der Schatten folgt der echten Kontur des Motivs, und das Originalfoto bleibt immer erhalten.

3D OHNE MATHEMATIK
• Greif knapp neben einer Seite und dreh jede Ebene in die Tiefe, in echter Perspektive. Keine Achsen, keine Zahlen.
• Oder richte sie mit einem kleinen Feld im Inspektor aus. Genaue Gradzahlen gibt es, wenn du sie brauchst.

GEMEINSAM GESTALTEN
• Teile ein Design über iCloud mit allen, die einen Mac haben. Niemand muss ein Konto anlegen.
• Änderungen werden Eigenschaft für Eigenschaft zusammengeführt. So arbeiten mehrere Leute gleichzeitig, und keine Änderung wird überschrieben.

DEINE KI GESTALTET MIT
• Bezzle hat einen eingebauten MCP-Server. Füge ihn mit einem Klick zu Claude Desktop hinzu oder verbinde einen anderen MCP-Assistenten.
• Der Assistent baut Screens, füllt Raster, erstellt Stapel, stellt frei und exportiert, und jeder Schritt lässt sich widerrufen.

EXPORT
• PNG, JPEG, SVG und PDF in 1x bis 4x: eine Zeichenfläche, eine Ebene oder alle Posts eines Stapels auf einmal.

GEMACHT FÜR DEN MAC
• Nativ und schnell, hell und dunkel, und Designs, die sich beim Arbeiten selbst sichern.
• Deine Designs bleiben auf deinem Mac oder in deiner eigenen iCloud. Kein Tracking, keine Werbung.

Kostenlos, mit allem drin. Einfach gestalten.""",
)

L["fr-FR"] = dict(
    name="Bezzle : Design UI & graphique",
    subtitle="Tous les outils pro, pour tous",
    promotionalText=f"Bezzle est gratuit. Ni version d’essai ni freemium{NB}: tous les outils, tous les exports et la création à plusieurs via iCloud, sans abonnement et sans compte.",
    keywords="maquette,wireframe,vectoriel,réseaux sociaux,carrousel,affiche,ux,web,logo,icône,détourage",
    description=f"""Bezzle est un studio de design complet pour ton Mac, et il est gratuit. Ni version d’essai ni freemium{NB}: pas d’abonnement, pas de compte, aucune fonction réservée. Tous les outils et tous les exports sont à toi dès le premier lancement.

Bezzle réunit les meilleures idées des apps de design que tu connais{NB}: plans de travail et grilles de répétition, coins squircle tout en douceur, vrais outils vectoriels, création à plusieurs et la rapidité d’une app Mac native. Chacune y devient plus simple. Puis Bezzle ajoute ce qu’aucune n’a{NB}: des piles pour les réseaux sociaux, le détourage en un clic, la 3D que tu tournes à la main et un assistant IA qui crée avec toi.

OUVRE CE QUE TU AS DÉJÀ
• Ouvre les fichiers Adobe XD, Figma (.fig) et Sketch, avec plans de travail, calques, textes, images, dégradés et ombres.
• Un court rapport montre ce qui a été repris, pour que rien ne change sans que tu le saches.

APPS, SITES WEB, POSTS ET PRINT
• Des plans de travail pour téléphones, tablettes, portables, écrans, montres, posts, stories et A4, côte à côte à l’échelle réelle.
• Plume, cutter, générateur de formes et opérations booléennes, et des coins que tu arrondis en les tirant, directement sur la toile.
• Coins squircle, dégradés que tu tires sur la toile, flou d’arrière-plan, flou progressif et ombres intérieures comme extérieures.
• Les images remplissent n’importe quelle forme. Double-clique pour les déplacer et les redimensionner à l’intérieur.

GRILLES DE RÉPÉTITION
• Tire une poignée et une carte devient une liste ou une galerie. Modifie une cellule et toutes suivent.
• Glisse un dossier de photos, un fichier texte ou un tableur sur une grille, et chaque cellule reçoit son propre contenu.
• Des noms, villes, prix, dates et titres d’exemple te permettent de juger une mise en page avant le vrai contenu.

DES PILES POUR LES RÉSEAUX SOCIAUX
• Des dizaines de posts sur un seul plan de travail, empilés comme des cartes. Change le style de l’un et tous suivent.
• Chaque post garde ses propres textes et photos. Étale la pile pour réordonner, exporter ou retirer des posts.
• Des carrousels pour Instagram, LinkedIn et TikTok{NB}: un seul design large, exporté en une image par slide.

SUPPRIMER L’ARRIÈRE-PLAN
• Un clic détoure personnes, animaux et produits, cheveux compris, directement sur ton Mac.
• L’ombre suit le vrai contour du sujet, et la photo d’origine est toujours conservée.

LA 3D SANS CALCUL
• Saisis juste à côté d’un bord et fais pivoter n’importe quel calque en profondeur, en vraie perspective. Ni axes ni chiffres.
• Ou oriente-le avec un petit pavé dans l’inspecteur. Les degrés exacts sont là quand tu en as besoin.

CRÉER À PLUSIEURS
• Partage un design via iCloud avec toute personne qui a un Mac. Personne n’a besoin de créer de compte.
• Les modifications se fusionnent propriété par propriété{NB}: plusieurs personnes travaillent en même temps et rien n’est jamais écrasé.

TON IA CRÉE AVEC TOI
• Bezzle intègre un serveur MCP. Ajoute-le à Claude Desktop en un clic, ou connecte n’importe quel assistant MCP.
• L’assistant construit des écrans, remplit des grilles, crée des piles, détoure et exporte, et chaque étape peut être annulée.

EXPORT
• PNG, JPEG, SVG et PDF de 1x à 4x{NB}: un plan de travail, un calque ou tous les posts d’une pile d’un coup.

FAIT POUR LE MAC
• Natif et rapide, en clair comme en sombre, avec des designs qui s’enregistrent tout seuls pendant que tu travailles.
• Tes designs restent sur ton Mac ou dans ton propre iCloud. Aucun pistage, aucune pub.

Gratuit, tout compris. Il ne reste qu’à créer.""",
)

L["it"] = dict(
    name="Bezzle: Design UI e grafica",
    subtitle="Ogni strumento pro, per tutti",
    promotionalText="Bezzle è gratis. Non è una prova né un freemium: tutti gli strumenti, tutti gli export e il lavoro di squadra via iCloud, senza abbonamento e senza account.",
    keywords="mockup,wireframe,vettoriale,social media,carosello,poster,layout,web,logo,icona,volantino,scontorno",
    description="""Bezzle è uno studio di design completo per il tuo Mac, ed è gratis. Non è una prova né un freemium: niente abbonamento, niente account, nessuna funzione riservata. Tutti gli strumenti e tutti gli export sono tuoi dal primo avvio.

Bezzle riunisce le idee migliori delle app di design che conosci: tavole da disegno e griglie ripetute, angoli squircle morbidi, veri strumenti vettoriali, lavoro di squadra e la velocità di un’app nativa per Mac. Qui ognuna diventa più semplice. Poi Bezzle aggiunge ciò che nessuna ha: pile per i social, scontorno con un clic, 3D che ruoti a mano e un assistente IA che progetta con te.

APRI CIÒ CHE HAI GIÀ
• Apre file Adobe XD, Figma (.fig) e Sketch, con tavole, livelli, testi, immagini, sfumature e ombre.
• Un breve resoconto mostra cosa è stato importato, così nulla cambia a tua insaputa.

APP, SITI WEB, POST E STAMPA
• Tavole per smartphone, tablet, portatili, desktop, orologi, post, storie e A4, una accanto all’altra in scala reale.
• Penna, taglierino, generatore di forme e operazioni booleane, e angoli che arrotondi trascinandoli, direttamente sulla tela.
• Angoli squircle, sfumature che trascini sulla tela, sfocatura dello sfondo, sfocatura graduale e ombre interne ed esterne.
• Le immagini riempiono qualsiasi forma. Fai doppio clic per spostarle e ridimensionarle al suo interno.

GRIGLIE RIPETUTE
• Trascina una maniglia e una scheda diventa una lista o una galleria. Cambi una cella e tutte seguono.
• Trascina su una griglia una cartella di foto, un file di testo o un foglio di calcolo, e ogni cella riceve il suo contenuto.
• Nomi, città, prezzi, date e titoli di esempio ti fanno valutare un layout prima che arrivino i contenuti veri.

PILE PER I SOCIAL
• Decine di post su un’unica tavola, impilati come carte. Cambi lo stile di uno e tutti seguono.
• Ogni post tiene i suoi testi e le sue foto. Apri la pila a ventaglio per riordinare, esportare o togliere post.
• Caroselli per Instagram, LinkedIn e TikTok: un unico design largo, esportato come un’immagine per slide.

RIMUOVI SFONDO
• Un clic scontorna persone, animali e prodotti, capelli compresi, direttamente sul tuo Mac.
• L’ombra segue il vero contorno del soggetto, e la foto originale resta sempre.

3D SENZA CALCOLI
• Afferra appena fuori da un lato e ruota qualsiasi livello in profondità, in vera prospettiva. Niente assi, niente numeri.
• Oppure orientalo con un piccolo riquadro nell’ispettore. I gradi esatti ci sono quando servono.

PROGETTARE INSIEME
• Condividi un design via iCloud con chiunque abbia un Mac. Nessuno deve creare un account.
• Le modifiche si uniscono proprietà per proprietà: più persone lavorano insieme e nessuna modifica viene sovrascritta.

LA TUA IA PROGETTA CON TE
• Bezzle ha un server MCP integrato. Aggiungilo a Claude Desktop con un clic o collega qualsiasi assistente MCP.
• L’assistente crea schermate, riempie griglie, prepara pile, scontorna ed esporta, e ogni passo si può annullare.

EXPORT
• PNG, JPEG, SVG e PDF da 1x a 4x: una tavola, un livello o tutti i post di una pila in una volta.

FATTO PER IL MAC
• Nativo e veloce, chiaro e scuro, con design che si salvano da soli mentre lavori.
• I tuoi design restano sul tuo Mac o nel tuo iCloud. Nessun tracciamento, nessuna pubblicità.

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
        "Nothing is sent anywhere else. The app collects no data.\n\n"
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
