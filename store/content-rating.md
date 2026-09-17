# Content rating (IARC questionnaire): GOTTA.BIKE: BLE Watts

How to answer Google Play's content rating questionnaire for this app. Google
runs it with the International Age Rating Coalition (IARC). Your answers are
turned into age ratings for each region. **Answer every question truthfully
for the build you are submitting.** Questions and labels in Play Console can
change, so treat the tables below as guidance, not as the literal wording.

## Where and how

Google's steps for the questionnaire
([Content rating requirements](https://support.google.com/googleplay/android-developer/answer/188189)):

1. Open Play Console and go to **Policy > App content**.
2. Under **Content ratings**, click **Start**.
3. Read the information and enter an email address. It "will be used for
   correspondence with International Age Rating Coalition (IARC)". Use
   `[CONTACT EMAIL]`.
4. **Select a category** and click **Next**.
5. Complete the questionnaire.
6. Review the calculated ratings on the **Summary** page and submit.

Every app needs a rating. "Apps without a content rating will be removed from
the Play Store", and you must submit a new questionnaire "whenever your app's
content changes"
([Content ratings](https://support.google.com/googleplay/android-developer/answer/9898843)).

## Category

Choose **"Utility, Productivity, Communication, or Other"**. Google says to
use it "for any app that doesn't belong to other listed categories". Its
examples include utilities and fitness apps
([category description](https://support.google.com/googleplay/android-developer/answer/6159978)).

The app is a Bluetooth sensor emulator and test utility. It isn't a game,
social network, news or reference app, or a store, so don't pick the Game,
social or news/reference/educational categories.

## Answers

The app has no story, characters, images, audio, chat, web content,
purchases or gambling. Its only content is its own UI, numbers and a chart.

| Topic | Answer | Why |
|---|---|---|
| Violence (any kind, including against non-human or fantasy characters) | **No** | None. |
| Blood, gore, disturbing or scary content | **No** | None. |
| Sexual content, nudity, suggestive themes | **No** | None. |
| Offensive language, crude humor | **No** | Fixed UI text only. The only free text is what users type into names. See "User-generated content" below. |
| Illegal, recreational or controlled drugs, alcohol, tobacco | **No** | None. |
| Gambling, simulated gambling, real gambling or cash payouts | **No** | None. |
| Discrimination or hate | **No** | None. |

### Interactive elements

IARC shows these labels next to a rating: **Users Interact**, **Shares
Location**, **Digital Purchases** (or In-Game Purchases) and **Unrestricted
Internet**
([How IARC works](https://globalratings.com/how-iarc-works/)).

| Question | Answer | Why |
|---|---|---|
| Can users interact or exchange content with other users (chat, voice, messages, image or audio sharing)? | **No** | No accounts, chat or social features. The Bluetooth link carries simulated sensor values to the user's own apps and devices. |
| Does the app share the user's current physical location with other users? | **No** | The app never reads location. On Android 11 and lower, `ACCESS_FINE_LOCATION` exists only because Bluetooth LE requires it. |
| Can users buy digital goods or make in-app purchases (including random items)? | **No** | Free, with no in-app purchases. |
| Does the app give unrestricted internet access (for example a web browser)? | **No** | No browser or web view, and the release manifest has no `INTERNET` permission (see `store/data-safety.md`). |
| Does the app contain ads? (if asked) | **No** | No ad SDK. |

### User-generated content

The only text a user can enter goes into the advertised device name (20
characters at most, `kMaxDeviceNameLength` in `lib/device_identity.dart`),
the manufacturer and model strings (40 characters at most) and preset or
profile names. That text stays in the app, except for the device name,
manufacturer and model. Those three are exposed as Bluetooth identification
strings to nearby devices while the user is broadcasting, much like a
phone's own Bluetooth name. This is a device label, not a feature for
sharing content between users or communicating, so answer **No** to
user-interaction and content-sharing questions.

## Expected result

With these answers, the app should get each authority's lowest age rating,
for example ESRB "Everyone", PEGI 3 and USK 0. The questionnaire decides the
actual ratings, so check the Summary page before you submit.

Rating authorities include ESRB (Americas), PEGI (Europe and the Middle
East), USK (Germany), ClassInd (Brazil), ACB (Australia, games only), GRAC
(South Korea, games only) and IARC Generic (other countries). A "Google Play
Rating" is used for apps in South Korea and Russia
([source](https://support.google.com/googleplay/android-developer/answer/188189)).

## Redo the questionnaire if...

- you add any communication, sharing or social feature, including sharing
  profiles with other users;
- you add a web view, links that open arbitrary web content, ads or
  purchases;
- you add location use beyond the Android 11 Bluetooth requirement;
- store screenshots or descriptions start showing content that these answers
  don't cover.

## Related (separate) App content sections

- **Target audience and content:** choose **Ages 18 and over**. If you
  include any group under 13, the app has to meet the Families policy
  ([Target audience](https://support.google.com/googleplay/android-developer/answer/9867159)).
  See `store/release-checklist.md` for the reasoning.
- **Ads:** declare that the app does **not** contain ads.
- **Data safety:** see `store/data-safety.md`.
