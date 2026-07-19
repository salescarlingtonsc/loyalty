# Frenly PDPA Operations Runbook

Status: **pre-launch control document**  
Owner: **not yet assigned**  
Last reviewed: **19 July 2026**  
Jurisdiction: **Singapore**

This is an operational baseline, not legal advice or a claim of certification. The owner must obtain Singapore legal review before relying on the public notices or merchant terms for general availability.

## P0 launch decision

Public launch is **blocked** until every item in this table has a named owner, dated evidence and a passing review.

| Gate | Current evidence | Required owner action | Pass evidence |
|---|---|---|---|
| Legal operator identity | The repository does not establish Frenly's legal entity name, UEN, registered/business address or service address. | Confirm the contracting Singapore person/entity and insert its legal identity and service details into the Terms, Privacy Notice, subscription/order flow and merchant contract. | Counsel-approved entity details appear consistently in all public and commercial surfaces. |
| Formal DPO designation | The public pages deliberately identify only `leechuanseng.biz@gmail.com` as an **Interim Privacy Contact**. There is no evidence of a formal DPO designation. | The governing owner must designate at least one DPO in writing, define authority and reporting line, provide a monitored business contact, and record acceptance of the role. | Signed designation record, role description, escalation cover and monitoring test. |
| DPO registration and public contact | No registration evidence exists. | Register or update the DPO through the current PDPC online registration process using an authorised Corppass user. ACRA BizFile+ registration has been unavailable since 1 December 2024; follow the current PDPC process. Update the public notice from interim contact to the verified DPO business contact after designation. | PDPC submission acknowledgement, screenshot/export of submitted details, and live public contact test. Formal designation and public availability are legal duties; registration is an additional Frenly launch-control requirement based on current PDPC guidance. |
| Role allocation with merchants | Public wording distinguishes the roles, but no merchant data-processing agreement is present. | Approve a merchant agreement/DPA that maps activities where the merchant is the organisation and Frenly is its data intermediary, and activities where Frenly acts as an organisation for its own purposes. | Signed template, processing instructions, security schedule, subprocessor terms, breach-notice obligation and deletion/return terms. |
| Production location and transfers | The notice says the production database is configured in Singapore and that other providers may process abroad. Database transfer is still in progress. | Complete Singapore cutover, verify the live application no longer sends personal data to the legacy region, inventory every provider/location and document transfer safeguards. Do not publish the location statement before the fact is true. | Live endpoint evidence, provider list, data-flow map, contractual transfer assessment and owner sign-off. |
| Data inventory and retention | Code and audit documents identify broad fields, but there is no approved record-level retention schedule. | Inventory each field/system, purpose, role, source, disclosure, location and disposal rule. Approve legal/business retention triggers rather than arbitrary universal periods. | Approved inventory and schedule with tested deletion/anonymisation jobs and backup-expiry evidence. |
| Data requests | A manual public email process now exists; there is no demonstrated case log, identity-verification procedure or trained backup owner. | Establish the register, verification matrix, merchant routing, exception review, secure response method and absence cover. Rehearse access, correction, withdrawal and deletion cases. | Completed tabletop records and evidence that the mailbox is monitored and cases are auditable. |
| Consent, marketing and DNC | The join experience records a general marketing flag. Channel-specific communications and DNC evidence controls are not proven. | Define consent wording by channel and merchant; preserve source, text/version, time and withdrawal. Implement suppression before campaigns. For covered Singapore telephone marketing, implement DNC checks or retain clear, unambiguous consent in evidential form, sender identification and same-medium opt-out. | End-to-end consent/withdrawal/DNC test and immutable campaign eligibility evidence. |
| Security and breach response | Technical hardening work is in progress; no full incident rehearsal is evidenced here. | Complete launch security gates, access review, backups/restore, log minimisation, incident roles and breach assessment/notification rehearsal. | Security review, restore test, breach tabletop and remediation log. |
| Children | No age-assurance or child-specific merchant control is demonstrated. | Decide whether child access is likely for each merchant sector. Apply data minimisation, age-appropriate notices and parent/guardian involvement where appropriate; do not collect identity documents merely to estimate age. | Documented sector decision, configured safeguards and tested guardian request path. |

## 1. Role model

Frenly must determine its PDPA role per processing activity, not once for the whole product.

| Activity | Merchant role | Frenly role | Operational consequence |
|---|---|---|---|
| Merchant customer profile, booking, sale, loyalty balance, notes and merchant marketing | Usually the organisation deciding purposes and means | Usually data intermediary processing under contract and instructions | Merchant provides the customer notice and decides requests; Frenly secures, retains and returns/deletes data under the DPA and assists promptly. |
| Merchant staff records and permissions entered for workforce operations | Usually the organisation/employer | Usually data intermediary | Merchant controls employment purpose and access; Frenly applies role isolation, audit and instruction handling. |
| Frenly account authentication, platform security, abuse prevention, direct support and legal compliance | May provide user information and cooperate | Organisation for Frenly's own purposes | Frenly must notify purposes, limit collection, handle rights, make retention decisions and maintain direct accountability. |
| Frenly subscription administration and commercial relationship | Customer organisation | Organisation | Commercial records require their own purpose, access and retention controls. Do not describe a ledger entry as regulated payment processing. |
| Merchant campaign content, recipient selection and DNC compliance | Organisation and sender/authoriser | Data intermediary if only executing instructions; may incur direct DNC responsibility depending on sending role | Contractually allocate checks, suppression, sender identification, consent evidence and complaint handling. Block sending unless evidence passes. |
| Aggregated service improvement | Merchant role depends on source and agreement | Organisation if Frenly determines a separate purpose | Use genuinely anonymised data where possible. Do not repurpose identifiable tenant data without a documented lawful basis, notice and contract right. |

The PDPC explains that a data intermediary processes personal data on behalf of another organisation and has role-specific duties; the engaging organisation remains responsible for data processed on its behalf. Frenly may occupy both roles for different activities.

## 2. Required registers

Keep these in a controlled system with access logs. Do not store request identity documents or customer exports in this repository.

1. **Personal data inventory:** field/category, data subject, collection source, purpose, legal/consent basis, Frenly role, merchant role, systems, region, recipients, retention trigger and disposal method.
2. **Vendor/subprocessor register:** service, data categories, purpose, locations/support access, contract, transfer safeguard, security review, breach contact, exit/export/deletion method and annual review date.
3. **Consent register:** merchant, customer, channel, action, exact notice/version, source, time, actor, evidence, withdrawal time and suppression result.
4. **Data request register:** reference, received date, scope, responsible organisation, identity method, searches, exceptions, fee if lawfully applicable, response date, disclosure channel and evidence deleted after completion.
5. **Incident register:** discovery, systems/data, containment, affected count, harm assessment, scale assessment, decision maker, notification decision/times, corrective actions and closure approval.
6. **Access register:** staff role, approval, branch/tenant scope, last review, termination date and anomalous-access review.
7. **Retention exception/legal hold register:** record set, reason, approver, review date and release action.

## 3. Data request procedure

### Intake and acknowledgement

- Monitor `leechuanseng.biz@gmail.com` every business day until a dedicated privacy mailbox and formally designated DPO contact replace it.
- Create a case reference immediately. Acknowledge receipt without confirming that the named record exists.
- Identify request type: access, correction, withdrawal, deletion/closure, complaint, incident or merchant service dispute.
- Identify whether Frenly or the merchant controls the requested processing. If the merchant is responsible, obtain the requester's permission where needed to route it; do not silently disclose the request to an unrelated merchant.

### Identity and authority

- Use the least intrusive reliable method: authenticated merchant account, a response through an already verified contact channel, or matching limited account facts.
- Never request passwords, OTPs, full card numbers, Singpass credentials or bank logins.
- Request an identity-document copy only if the risk cannot reasonably be managed another way and the collection is lawful, necessary and protected. Redact unnecessary fields and delete the copy promptly after verification.
- For a representative, verify both the data subject and authority. For a child, use proportionate parent/guardian verification and an age-appropriate explanation.

### Search, review and response

- Preserve responsive data when a request is received; suspend routine deletion for that case only.
- Search production, relevant audit records, support systems and active vendor systems. Do not restore every backup solely to search unless required; document protected backup handling.
- For access, assess prohibitions/exceptions and avoid disclosing another person's data, confidential commercial material or security secrets. Use a secure delivery channel.
- For correction, confirm the accurate value, update authoritative records and assess onward correction obligations.
- For withdrawal, explain likely consequences, record reasonable notice, stop the consent-dependent activity and verify suppression. Withdrawal does not invalidate prior lawful processing.
- For deletion/closure, determine whether purpose, legal, security, dispute, audit or financial needs require continued retention. Delete or de-identify the rest and record backup expiry.
- The PDPC states that organisations must respond to access requests within 30 calendar days; if unable to provide access in that period, the organisation must inform the individual in writing when it will respond. Treat this as the regulatory outer response control, not a marketing promise. Correction and withdrawal should be processed as soon as practicable after verification and required notices.

## 4. Marketing and DNC control

No merchant campaign should send until these checks are machine-enforced and auditable:

1. The merchant is identified as sender/authoriser and has accepted responsibility for content and audience.
2. The intended channel has an affirmative, current consent record or another documented lawful route.
3. A prior withdrawal or suppression always wins over an import, duplicate profile or later bulk edit.
4. For covered marketing to Singapore telephone numbers, a valid DNC check is recorded unless a documented exception or clear and unambiguous consent applies.
5. The message identifies the sender, gives contact information where required and provides an opt-out using the same medium.
6. The opt-out updates the suppression list without requiring login, purchase or excessive information. PDPC guidance says telephone marketing must stop within 21 days after an opt-out; Frenly's operational target should be immediate suppression.
7. Service messages are separated from promotional content. Do not add marketing to a service message to avoid campaign controls.

## 5. Retention and disposal

The DPO and business owner must approve a schedule after legal and accounting review. Use event-based triggers:

| Record | Start trigger | Disposal rule to approve |
|---|---|---|
| Prospective merchant lead | Last meaningful contact or opt-out | Delete/de-identify when no current purpose or legal need remains. |
| Active merchant account and authorised users | Account closure or user removal | Remove access immediately; retain only records needed for contract, security, dispute or law. |
| Merchant customer/booking/loyalty records | Merchant instruction, account closure or end of customer purpose | Return/export where contracted; delete/de-identify unless legal/business need is documented. Preserve financial integrity without retaining unnecessary profile fields. |
| Consent and suppression evidence | End of messaging relationship | Retain enough evidence to honour suppression and demonstrate compliance; restrict use. |
| Security and audit logs | Log event | Keep only the detail and duration justified by detection, investigation and accountability; minimise IP and payload data. |
| Support and privacy cases | Case closure | Remove attachments and identity evidence first; retain a minimal outcome/audit record for the approved period. |
| Backups | Production deletion | Make data unavailable to ordinary users, prevent restoration to live use without reapplying deletions, and let encrypted backup copies expire on the verified provider cycle. |

Run quarterly disposal checks and sample evidence. A deletion statement is not complete until production, replicas, search indexes, exports, vendor systems and backup behaviour are addressed.

## 6. Vendor and transfer management

- Confirm the Singapore region for the production database through live endpoint and provider-console evidence after cutover.
- Treat web hosting, CDN, font/library delivery, support and operational access as separate data flows. A Singapore database does not mean every technical datum remains in Singapore.
- Before onboarding a provider, review instructions, confidentiality, security, subprocessing, locations, comparable-protection mechanism, incident notification, audit evidence, return/deletion and exit support.
- Minimise browser disclosure to third-party font and CDN providers. Prefer self-hosted, pinned assets where practical.
- Review the register annually and on every material vendor, purpose, region or contract change.

## 7. Security baseline

- Enforce tenant isolation and row-level access policies; deny by default and test anonymous/authenticated/role boundaries.
- Require individual staff accounts, strong authentication, secure recovery, prompt offboarding and quarterly access recertification.
- Keep privileged keys out of browser code, source control, support tickets and analytics. Rotate after suspected disclosure.
- Protect public join/booking actions with validation, rate limits and non-enumerable responses. Require one-time proof for customer record access or change; phone number alone is not authentication.
- Log security-relevant events without raw customer profiles, message contents, tokens or unnecessary IP addresses.
- Patch dependencies, scan configuration, preserve immutable financial/audit events and test backups and restore.
- Conduct an independent penetration test before broad launch and after material authentication or tenant-boundary changes.

## 8. Incident and breach response

1. **Detect and contain:** page the incident owner, stop exposure, preserve evidence and avoid destructive cleanup.
2. **Scope:** identify systems, data categories, encryption/access status, affected people/merchants, dates, recipients and ongoing risk.
3. **Notify merchants:** where Frenly is a data intermediary, notify the responsible organisation without undue delay and provide information needed for its assessment.
4. **Assess:** the responsible organisation assesses whether the breach is likely to cause significant harm and/or is of significant scale. Record the reasoning even when not notifiable.
5. **Notify:** where notifiable, notify the PDPC as soon as practicable and no later than three calendar days after making the assessment; notify affected individuals as soon as practicable where required. Do not wait for a perfect forensic report before meeting a deadline.
6. **Recover and learn:** validate containment, rotate credentials, restore safely, monitor recurrence, complete root-cause analysis and track corrective actions to closure.

Maintain current PDPC reporting links and counsel/forensics contacts in the private incident plan, not in the public repository.

## 9. Merchant onboarding and offboarding

### Onboarding

- Execute Terms and DPA before importing personal data.
- Record legal entity, UEN, merchant privacy contact, sector, likely child use, data types, marketing channels and migration source.
- Require the merchant to confirm notices, consent evidence, DNC process and authority for imported lists.
- Create least-privilege owner/staff accounts and test branch isolation.
- Reject files containing card data, passwords, identity-document images or unsupported sensitive data.

### Offboarding

- Confirm authorised closure and freeze new processing.
- Export data securely within contract scope; log recipient and checksum without storing the export in git.
- Revoke users, public links, API credentials and scheduled jobs.
- Resolve customer balances, merchant liabilities, disputes and legal holds before deleting profile data.
- Delete/de-identify according to the schedule and contract; obtain vendor deletion/expiry evidence where appropriate.

## 10. Review cadence and evidence

| Frequency | Review |
|---|---|
| Daily | Privacy mailbox, incidents, failed security alerts and urgent opt-outs. |
| Monthly | Open requests, overdue actions, consent/suppression failures, privileged access and vendor incidents. |
| Quarterly | Access recertification, retention disposal sample, restore test, public-page/contact test and merchant DNC sample. |
| Annually | Full data inventory, DPO designation/registration/contact, vendor/transfer assessment, merchant DPA, training, incident exercise and legal review. |
| Event-driven | New feature/data field, new vendor/region, acquisition, material incident, new marketing channel, child-facing merchant sector or legal change. |

## Official Singapore references

- [PDPC: Data Protection Obligations](https://www.pdpc.gov.sg/overview-of-pdpa/the-legislation/personal-data-protection-act/data-protection-obligations)
- [PDPC: Register Your Data Protection Officer](https://www.pdpc.gov.sg/overview-of-pdpa/data-protection/business-owner/data-protection-officers)
- [PDPC: Guide to Notification](https://www.pdpc.gov.sg/help-and-resources/2019/09/guide-to-notification)
- [PDPC: Guide to Handling Access Requests](https://www.pdpc.gov.sg/help-and-resources/2017/10/guide-to-handling-access-requests)
- [PDPC: Guide to Managing Data Intermediaries](https://www.pdpc.gov.sg/help-and-resources/2020/09/guide-to-managing-data-intermediaries)
- [PDPC: Advisory Guidelines on the PDPA for Selected Topics](https://www.pdpc.gov.sg/guidelines-and-consultation/2020/02/advisory-guidelines-on-the-personal-data-protection-act-for-selected-topics)
- [PDPC: Do Not Call Registry and Your Business](https://www.pdpc.gov.sg/overview-of-pdpa/do-not-call-registry/business-owner/do-not-call-registry-and-your-business)
- [PDPC: Children's Personal Data in the Digital Environment](https://www.pdpc.gov.sg/guidelines-and-consultation/2024/03/advisory-guidelines-on-the-pdpa-for-childrens-personal-data-in-the-digital-environment)
- [PDPC: Managing Personal Data](https://www.pdpc.gov.sg/overview-of-pdpa/data-protection/business-owner/managing-personal-data)

Before each annual review, verify that these sources and registration/reporting routes remain current.
