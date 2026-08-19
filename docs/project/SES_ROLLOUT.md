# Amazon SES rollout

## Nieuwe runtimevariabelen

`EMAIL_PROVIDER=ses`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `SES_FROM_NAME`, `SES_FROM_EMAIL`, `SES_REPLY_TO_EMAIL`, `SES_CONFIGURATION_SET`, `SES_SMOKE_RECIPIENT`, `SES_SNS_TOPIC_ARN` en tijdelijk `SES_SNS_AUTO_CONFIRM=true` voor de ondertekende subscription confirmation. Zet auto-confirm direct daarna terug op `false`.

## AWS-stappen buiten de code

1. Verifieer het Duindorp-afzenderdomein (DKIM/SPF/DMARC) en vraag SES production access voor staging aan.
2. Maak een least-privilege IAM-principal die uitsluitend `ses:SendEmail` voor de bedoelde identity/configuration set mag uitvoeren.
3. Maak de configuration set en een SNS event destination voor SEND, DELIVERY, BOUNCE, COMPLAINT, REJECT en DELIVERY_DELAY.
4. Maak een staging-SNS-topic, configureer `SES_SNS_TOPIC_ARN`, abonneer `https://<staging>/api/webhooks/ses` en bevestig uitsluitend via de geverifieerde callback.

## Exacte stagingacceptatie

1. Houd de databaseflag en `EMAIL_ENABLED` eerst uit; deploy de configuratie en controleer generieke health.
2. Zet `EMAIL_PROVIDER=ses`, laad alleen stagingcredentials en zet de verzendpoort gecontroleerd aan.
3. Verstuur de beheer-testmail en bewijs dezelfde immutable test-ID, SES MessageId, inbox en signed DELIVERY.
4. Bewijs met SES test/simulatoradressen BOUNCE, COMPLAINT, REJECT en DELIVERY_DELAY; replay exact hetzelfde SNS-bericht en controleer één idempotent ledgerresultaat.
5. Bewijs een ouder-OTP en een gewone job zonder PII in tags/logs, controleer retries/uncertainty en laat alle health- en releasepoorten groen worden.
6. Promoveer pas daarna met afzonderlijke productieapproval; maak vanuit deze repository geen productiecredentials of providerresources aan.

## Rollback

Zet verzending eerst uit, herstel de bestaande SendGrid-secrets/webhookbinding, zet expliciet `EMAIL_PROVIDER=sendgrid`, controleer fingerprint/health en zet daarna verzending weer aan. Database, snapshots en queues hoeven niet te worden teruggedraaid. Reconcileer onzekere SES-pogingen vóór herverzending om dubbele mail te voorkomen.
