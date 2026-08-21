# Duindorp SV Tenueportaal — bindend MVP-addendum v1.2

Status: expliciet geautoriseerd door de product owner op 21 augustus 2026.

Dit addendum vervangt canon v1.0 en addendum v1.1 uitsluitend voor de hieronder
genoemde onderwerpen. Alle overige bepalingen blijven ongewijzigd bindend. De
portaaluitnodiging uit addendum v1.1 blijft nadrukkelijk tokenloos; de nieuwe
inloggegevens ontstaan uitsluitend na een eigen ouderloginverzoek.

## 1. Eén stabiele ouderloginuitdaging

- Per ouderaccount bestaat normaal maximaal één bruikbare loginuitdaging. Zij leeft
  exact tien minuten vanaf de oorspronkelijke aanmaak en bevat logisch één stabiele
  zescijferige code en één onafhankelijke stabiele directe-inlogproof.
- Een openbare heraanvraag of support-resend tijdens die levensduur hergebruikt
  dezelfde uitdaging, code, proof en vervaldatum. Resend verlengt de geldigheid niet
  en maakt de eerder verzonden mail niet ongeldig.
- Een nieuwe uitdaging ontstaat uitsluitend nadat de vorige is verlopen, verbruikt,
  na vijf mislukte verificatiepogingen geblokkeerd of via de expliciete supportreset
  ingetrokken. Een bewuste nieuwe-codeactie waarschuwt dat de huidige code vervalt.
- De openbare resendcooldown is negentig seconden. De bestaande uur- en IP-limieten
  blijven gelden voor aanvragen en verzendingen; support gebruikt daarnaast een
  afzonderlijke begrensde rate-limit.
- De server maakt eerst een random challenge-UUID. Code en linkproof worden
  deterministisch maar domeingescheiden afgeleid met HMAC en het bestaande
  server-only oudergeheim. De mapping naar zes cijfers voorkomt modulobias. UUID,
  account-ID of challenge-ID alleen is nooit voldoende voor authenticatie.
- Plaintext code en linkproof staan nooit in PostgreSQL, audit-, operationele of
  providerlogs, API-responses, browserconsole, analytics of de backoffice. Een hash
  mag als verificatiebewijs worden bewaard. Pepperrotatie blijft een gecontroleerde
  intrekking van open uitdagingen en bestaande sessies vereisen.

## 2. Code en optionele directe inloglink

- Iedere `login_otp`-mail bevat zowel de zescijferige code als de knop
  `Direct inloggen`. Er komt geen tweede OTP-template en de portaaluitnodiging bevat
  geen van beide credentials.
- De directe-inlogproof is gebonden aan exact dezelfde uitdaging, ouderidentiteit en
  vervaldatum als de code. Succes via code of link zet dezelfde uitdaging atomair op
  verbruikt; de andere methode en iedere replay falen daarna.
- De mail gebruikt `/login/direct#<credential>`. Het fragment bereikt de server niet
  bij de initiële GET. De client verwijdert het fragment onmiddellijk uit adresbalk
  en historie, laadt geen derde-partijassets en POST de proof same-origin naar een
  begrensde verificatieroute.
- De directe pagina en verificatieresponses gebruiken `Cache-Control: no-store` en
  een gesloten `Referrer-Policy`. Credential, parent-, member- en challenge-ID komen
  niet in querystrings. Na succes ontstaat dezelfde opaque, herroepbare,
  HttpOnly/Secure/SameSite-oudersessie als bij codeverificatie en volgt redirect naar
  `/mijn-tenue`.
- De leden-UI toont een gemaskeerd adres, resterende geldigheid, resendcountdown,
  duidelijke hulp en generieke foutcopy. Bekende en onbekende adressen behouden
  dezelfde openbare status, responsevorm en zo gelijk mogelijke timing.

## 3. Backoffice-support en rollen

- De drie personeelsrollen blijven exact `beheerder`, `kledingcommissie` en
  `uitgifte`; er ontstaat geen supportrol of losse maatwerkpermissie.
- Alleen een beheerder met een actuele AAL2-sessie mag voor het bestaande
  ouderaccount de actuele loginstatus en gemaskeerde aflevermetadata zien, dezelfde
  verificatiemail opnieuw versturen of alle open uitdagingen intrekken en exact één
  nieuwe laten verzenden. De kledingcommissie kan problemen via het gemaskeerde
  ontvangersoverzicht signaleren, maar bedient de geprivilegieerde OTP-supportactie
  niet.
- Deze acties sturen uitsluitend naar het geregistreerde ouderadres, retourneren
  alleen veilige deliverymetadata, tonen nooit code/proof en zijn rate-limited,
  request-idempotent en append-only geaudit.
- Alleen de beheerder beheert grants, portaaltoegang, ouderidentiteit,
  e-mailadreswijziging, suppressieopheffing en sessie-intrekking. De begrensde
  OTP-supportactie verruimt geen grant en trekt geen bestaande oudersessie in.
  `uitgifte` heeft geen toegang tot deze gegevens of acties.
- Eén ouderaccount blijft de loginidentiteit voor alle werkelijk gegrante
  lid-seizoenen. Support maakt nooit een OTP per kind.

## 4. Providerbewijs en Email Control Center

- Mail-v2 blijft de enige template-, render-, queue-, attempt- en eventarchitectuur.
  `login_otp` behoudt de afzonderlijke codevrije immutable afleverledger. De actieve
  provider is expliciet omgevingsgebonden: SendGrid of de tijdelijke VoetbalAssist
  SMTP-adapter. Er komt geen parallelle queue of eventledger.
- Canonieke aflevertoestanden onderscheiden minimaal `queued`, `processing`,
  `provider_accepted`, `delivered`, `temporary_failure`, `permanent_rejection`,
  `delivery_uncertain`, `bounced`, `dropped`, `complaint`, `suppressed` en
  `superseded`. Bestaande jobstatussen mogen via projectie worden behouden.
- Nodemailer-acceptatie en een SMTP-message-ID bewijzen alleen overdracht aan de
  upstream SMTP-server. UI, health en audit noemen dit `Geaccepteerd door SMTP` of
  `Overgedragen aan mailserver`, nooit `Afgeleverd`.
- Alleen downstream bewijs, zoals een geldig ondertekend SendGrid-event of een
  veilig geconfigureerde en gevalideerde DSN, mag `delivered`, `bounced`, `dropped`
  of vergelijkbaar eindbewijs projecteren. Zonder zo'n kanaal blijft aflevering
  onbevestigd.
- Providerbewijs bewaart uitsluitend veilige gestructureerde velden: provider,
  provider-message-ID, SMTP-responsecode, enhanced status code, uitkomst en tijd.
  Credentials en ruwe SMTP-conversaties worden niet opgeslagen. Classificatie van
  tijdelijke 4xx, permanente recipient-5xx en onzekere DATA-uitkomsten is centraal
  providergebonden.
- Providerfeedback is expliciet als `smtp_sync_only`, `smtp_dsn` of
  `sendgrid_webhook` zichtbaar. DSN-ingestie blijft optioneel, environment-driven,
  standaard uit en wordt alleen geactiveerd met werkelijk beschikbare mailbox- en
  authenticatieconfiguratie. Vrije bounceprose alleen is geen correlatiebewijs.
- `/backoffice/emails` blijft campagnes, reminders, templates en branding bevatten
  en voegt operationele overzichten toe voor problemen, ontvangers, login/OTP en
  mailstroom. Lage-privilegeweergaven maskeren adressen; secrets en provideraccounts
  worden nooit getoond.

## 5. Ontvangergezondheid, suppressie en globale health

- Ontvangergezondheid is een projectie per genormaliseerd historisch e-mailadres,
  gekoppeld aan het ouderaccount en de werkelijk geautoriseerde kinderen. Een
  gezins-e-mailtransfer verplaatst of wist historische events/suppressie nooit; het
  nieuwe adres krijgt een eigen identiteit.
- De labels zijn bewijsgebonden: `Gezond` vereist bewezen aflevering zonder actueel
  probleem; `Geaccepteerd` betekent provideracceptatie zonder afleverbevestiging;
  daarnaast bestaan `Let op`, `Ongeldig/bounce`, `Onbekend` en `Onderdrukt`.
- `Structureel onbereikbaar` volgt alleen uit echte recente hard-bounce-, permanente
  recipient rejection- of herhaalde provider-bounce/dropbewijzen. Ontbrekend
  downstream feedback is nooit voldoende. Verdachte domeintypo's geven uitsluitend
  een conservatieve waarschuwing en worden nooit automatisch gecorrigeerd.
- Bewezen permanente recipient failure maakt één geaudite recipient-suppressie.
  Bulk en reminders stoppen voor dat adres. Securitymail wordt niet stil verworpen:
  de openbare OTP-route houdt een neutrale response en de gekozen providerpoging
  blijft in de ledger zichtbaar, terwijl staff het recipientprobleem ziet. Alleen een
  beheerder met AAL2 mag na een gecontroleerde adrescorrectie of nieuw bewijs de
  suppressie opheffen.
- Actiepunten aggregeren per ontvanger en probleemepisode. Eén bounce maakt de
  applicatie niet ongezond. Globale health degradeert alleen door systemische
  provider/configuratie-, queue-, worker-, scheduler-, database- of projectiefouten.

## 6. Release- en stagingbewijs

- Uitsluitend forward-only migraties zijn toegestaan. Historische SMTP-acceptatie
  wordt nooit naar `delivered` opgewaardeerd en oude generieke providerrejections
  veroorzaken niet zonder permanent recipientbewijs automatisch suppressie.
- De parent-loginacceptatie gebruikt alleen een expliciet geconfigureerde veilige
  stagingontvanger en run-unieke, zelfopruimende fixtures. Zij verstuurt geen bulkmail
  en toont of bewaart geen code, proof, sessiecookie, adres of credential-URL in logs
  of artifacts.
- De acceptatieworkflow controleert eerst actuele `main`, de succesvolle canonieke
  deployrun, release-SHA, artifactdigest en publieke stagingidentiteit. Bewijs bevat
  uitsluitend booleans, aantallen, tijden en niet-herleidbare runidentifiers.
- Productiepromotie valt buiten deze wijziging en wordt niet automatisch of
  handmatig door de stagingacceptatie gestart.
