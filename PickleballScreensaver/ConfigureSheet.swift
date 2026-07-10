import AppKit
import ScreenSaver

// MARK: - Configure sheet

/// Programmatic options panel shown from System Settings ("Options…").
/// The owning view must keep this controller alive for the sheet's lifetime,
/// and dismissal must go through sheetParent.endSheet — System Settings hangs
/// on close()/stopModal.
final class ConfigureSheetController: NSObject, NSTextFieldDelegate {

    private var weatherSettings = WeatherSettings.load()
    private var tournamentSettings = TournamentSettings.load()
    private var drillSettings = DrillSettings.load()
    private var pendingPlace: GeocodedPlace?

    private let weatherCheck = NSButton(checkboxWithTitle: "Show weather", target: nil, action: nil)
    private let cityField = NSTextField(string: "")
    private let lookupButton = NSButton(title: "Look Up", target: nil, action: nil)
    private let locationLabel = NSTextField(labelWithString: "No location set")
    private let fahrenheitRadio = NSButton(radioButtonWithTitle: "°F", target: nil, action: nil)
    private let celsiusRadio    = NSButton(radioButtonWithTitle: "°C", target: nil, action: nil)
    private let tournamentsCheck = NSButton(checkboxWithTitle: "Show nearby tournaments", target: nil, action: nil)
    private let tournamentsWindowPopup = NSPopUpButton()
    private let tournamentsHintLabel = NSTextField(wrappingLabelWithString:
        "Uses the weather city above — works best near a major US metro area.")
    private let drillCheck = NSButton(checkboxWithTitle: "Show drill of the day", target: nil, action: nil)
    private let drillLevelPopup = NSPopUpButton()

    private static let drillLevelChoices = ["all", "3.0", "3.5", "4.0", "5.0"]
    private static let drillLevelTitles = ["All levels", "3.0 Beginner", "3.5 Intermediate",
                                           "4.0 Advanced", "5.0 Pro"]
    private static let tournamentWindowChoices = [1, 3]
    private static let tournamentWindowTitles = ["Next 1 month", "Next 3 months"]

    private(set) lazy var window: NSWindow = buildWindow()

    /// Sync control state from persisted settings; the view calls this each
    /// time the sheet is requested so a cancelled edit doesn't linger.
    func refresh() {
        _ = window
        weatherSettings = WeatherSettings.load()
        tournamentSettings = TournamentSettings.load()
        drillSettings = DrillSettings.load()
        pendingPlace = nil
        weatherCheck.state = weatherSettings.enabled ? .on : .off
        cityField.stringValue = weatherSettings.locationName
        locationLabel.stringValue = weatherSettings.hasLocation
            ? weatherSettings.locationName
            : "No location set — enter a city and click Look Up."
        fahrenheitRadio.state = weatherSettings.useFahrenheit ? .on : .off
        celsiusRadio.state = weatherSettings.useFahrenheit ? .off : .on
        tournamentsCheck.state = tournamentSettings.enabled ? .on : .off
        tournamentsWindowPopup.selectItem(at: Self.tournamentWindowChoices.firstIndex(of: tournamentSettings.windowMonths) ?? 1)
        drillCheck.state = drillSettings.drillEnabled ? .on : .off
        drillLevelPopup.selectItem(at: Self.drillLevelChoices.firstIndex(of: drillSettings.drillLevel) ?? 0)
        updateEnabledState()
    }

    // MARK: Layout

    private func buildWindow() -> NSWindow {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                            styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = "Pickleball Screensaver Options"

        weatherCheck.target = self
        weatherCheck.action = #selector(weatherToggled(_:))
        for b in [fahrenheitRadio, celsiusRadio] {
            b.target = self
            b.action = #selector(unitChanged(_:))
        }
        drillLevelPopup.addItems(withTitles: Self.drillLevelTitles)
        drillCheck.target = self
        drillCheck.action = #selector(drillToggled(_:))

        tournamentsWindowPopup.addItems(withTitles: Self.tournamentWindowTitles)
        tournamentsCheck.target = self
        tournamentsCheck.action = #selector(tournamentsToggled(_:))
        tournamentsHintLabel.textColor = .secondaryLabelColor
        tournamentsHintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        lookupButton.target = self
        lookupButton.action = #selector(lookupCity(_:))
        cityField.placeholderString = "City, e.g. Austin"
        cityField.delegate = self
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        locationLabel.lineBreakMode = .byTruncatingTail

        let okButton = NSButton(title: "OK", target: self, action: #selector(ok(_:)))
        okButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"

        let extrasHeader = NSTextField(labelWithString: "Overlays:")
        extrasHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let stack = NSStackView(views: [
            extrasHeader,
            weatherCheck,
            indent(hstack([cityField, lookupButton])),
            indent(locationLabel),
            indent(hstack([NSTextField(labelWithString: "Units:"), fahrenheitRadio, celsiusRadio])),
            tournamentsCheck,
            indent(hstack([NSTextField(labelWithString: "Show:"), tournamentsWindowPopup])),
            indent(tournamentsHintLabel),
            drillCheck,
            indent(hstack([NSTextField(labelWithString: "Drill level:"), drillLevelPopup])),
            hstack([spacer(), cancelButton, okButton]),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            cityField.widthAnchor.constraint(equalToConstant: 220),
            locationLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            tournamentsHintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
        // The button row stretches to the sheet's full width
        stack.views.last!.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        panel.setContentSize(NSSize(width: 460, height: content.fittingSize.height))
        return panel
    }

    private func hstack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        return s
    }

    private func indent(_ view: NSView) -> NSStackView {
        let pad = NSView()
        pad.widthAnchor.constraint(equalToConstant: 18).isActive = true
        return hstack([pad, view])
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        return v
    }

    // MARK: Actions

    private func updateEnabledState() {
        let weatherOn = weatherCheck.state == .on
        cityField.isEnabled = weatherOn
        lookupButton.isEnabled = weatherOn
        fahrenheitRadio.isEnabled = weatherOn
        celsiusRadio.isEnabled = weatherOn
        drillLevelPopup.isEnabled = drillCheck.state == .on
        tournamentsCheck.isEnabled = weatherOn
        tournamentsWindowPopup.isEnabled = weatherOn && tournamentsCheck.state == .on
    }

    @objc private func weatherToggled(_ sender: Any?) {
        updateEnabledState()
    }

    @objc private func tournamentsToggled(_ sender: Any?) {
        updateEnabledState()
    }

    @objc private func drillToggled(_ sender: Any?) {
        updateEnabledState()
    }

    @objc private func unitChanged(_ sender: NSButton) {
        // Manual radio behaviour — the two buttons live in different stack
        // cells, so AppKit won't group them automatically.
        fahrenheitRadio.state = sender == fahrenheitRadio ? .on : .off
        celsiusRadio.state = sender == celsiusRadio ? .on : .off
    }

    // Editing the city invalidates an earlier lookup; OK must not persist
    // coordinates that no longer match the typed text.
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === cityField, pendingPlace != nil else { return }
        pendingPlace = nil
        locationLabel.stringValue = "Click Look Up to confirm this location."
    }

    @objc private func lookupCity(_ sender: Any?) {
        let query = cityField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        locationLabel.stringValue = "Looking up “\(query)”…"
        GeocodingClient.lookup(query) { [weak self] place in
            guard let self else { return }
            if let place {
                self.pendingPlace = place
                self.locationLabel.stringValue = "Found: \(place.displayName)"
            } else {
                self.locationLabel.stringValue = "No match for “\(query)” — check the spelling."
            }
        }
    }

    @objc private func ok(_ sender: Any?) {
        weatherSettings.enabled = weatherCheck.state == .on
        if let place = pendingPlace {
            weatherSettings.locationName = place.name
            weatherSettings.latitude = place.latitude
            weatherSettings.longitude = place.longitude
        }
        weatherSettings.useFahrenheit = fahrenheitRadio.state == .on
        weatherSettings.save()
        tournamentSettings.enabled = tournamentsCheck.state == .on && weatherSettings.enabled
        tournamentSettings.windowMonths = Self.tournamentWindowChoices[max(0, tournamentsWindowPopup.indexOfSelectedItem)]
        tournamentSettings.save()
        drillSettings.drillEnabled = drillCheck.state == .on
        drillSettings.drillLevel = Self.drillLevelChoices[max(0, drillLevelPopup.indexOfSelectedItem)]
        drillSettings.save()
        dismiss(.OK)
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss(.cancel)
    }

    private func dismiss(_ code: NSApplication.ModalResponse) {
        if let parent = window.sheetParent {
            parent.endSheet(window, returnCode: code)
        } else {
            window.orderOut(nil)   // standalone test host
        }
    }
}
