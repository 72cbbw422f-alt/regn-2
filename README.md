# VÄDER iOS

Native SwiftUI weather app. First milestone: visual prototype and automated unsigned iOS build.

## Project status

- [x] Private GitHub repository
- [x] SwiftUI app skeleton
- [x] Weather overview prototype with demonstration data
- [x] Five-tab navigation
- [x] GitHub Actions macOS build workflow
- [ ] Verify first cloud build
- [ ] Connect Foreca API through a secure backend
- [ ] Implement precipitation watch and notifications
- [ ] Add radar and official weather alerts

## Build without a local Mac

GitHub Actions runs on a hosted macOS machine with Xcode. Push to `main`, or run the workflow manually from the Actions tab.

The workflow uses XcodeGen to generate the Xcode project, builds for a generic iOS device with code signing disabled, and packages an unsigned IPA as a downloadable Actions artifact.

## Important

All displayed weather values are demonstration data. This prototype is not a live forecast and must not be used for weather-related decisions.

An unsigned IPA is not directly installable on a physical iPhone. It must first be signed with a valid Apple development/distribution identity and provisioning profile. Never put Apple certificates, passwords, Foreca API keys, or other secrets in source files. API credentials will be stored as GitHub Actions secrets or in the backend.

## Technology

- SwiftUI
- XcodeGen
- GitHub Actions / macOS
- Foreca as the planned primary weather provider
- Backend-mediated API access for secrets and notification processing

## Location privacy

Regnvakt uses the device location only to request a local weather forecast from Open-Meteo. The app displays the generic label “Din plats” rather than a city or locality name. Coordinates are sent to Open-Meteo to retrieve weather data; this repository does not contain a fixed personal location.
