/// The project's public web pages.
///
/// These moved off the `web.nymchat.app/static/*.html` paths onto the apex
/// domain as clean slugs (`nymchat.app/dmca/`), so they live in one place here
/// rather than as literals scattered across the modals that link to them.
library;

/// Apex domain serving the public pages. NOT the app/API host — that stays
/// `web.nymchat.app` (see `ApiConfig.apiHost`), which is a different thing.
const String kSiteBase = 'https://nymchat.app';

const String kDocsUrl = '$kSiteBase/docs/';
const String kTermsUrl = '$kSiteBase/tos/';
const String kPrivacyUrl = '$kSiteBase/pp/';
const String kDmcaUrl = '$kSiteBase/dmca/';

/// Public source repository.
const String kGithubUrl = 'https://github.com/Spl0itable/NYM';
