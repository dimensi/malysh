
#if DEBUG && targetEnvironment(simulator)
    fileprivate extension AppStore {
        /// In an isolated UI-test store only. The production app does not include this source.
        func prepareStorefrontFixture() throws {
            precondition(!persistence.cloudEnabled)
            let calendar = Calendar.current
            let now = Date()
            let reminderCapture = ProcessInfo.processInfo.arguments.contains("--storefront-reminder-system")
            let reminderBottle = now.addingTimeInterval(-3 * 3600 + 52)
            let today = calendar.startOfDay(for: now)
            func date(daysAgo: Int = 0, hour: Int, minute: Int = 0) -> Date {
                let day = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
                let hourStart = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
                return hourStart.addingTimeInterval(Double(minute) * 60)
            }

            let birth = date(daysAgo: 107, hour: 8, minute: 26)
            var baby = Baby(
                name: "Ванечка", birthDate: birth,
                parentProfiles: [
                    "owner": ParentProfile(name: "Лена", role: .mother),
                    "participant-1": ParentProfile(name: "Миша", role: .father),
                ],
                birthDateConfirmed: true
            )
            baby.birthTime = CivilTime(date: birth)
            baby.birthTimeZoneIdentifier = calendar.timeZone.identifier
            baby.explicitlyCreated = true

            guard let sharedStore = persistence.sharedStore else { throw Persistence.Failure.missingStore }
            let context = persistence.container.viewContext
            let object = NSEntityDescription.insertNewObject(forEntityName: "BabyRecord", into: context)
            context.assign(object, to: sharedStore)
            object.setValue(baby.id, forKey: "id")
            try persistence.saveBaby(baby)
            testingFamily = FamilySnapshot(isOwner: true, members: [
                FamilyMember(id: "owner", name: "Лена", role: "Мама",
                             status: "Владелец", isCurrentUser: true, isOwner: true),
                FamilyMember(id: "participant-1", name: "Миша", role: "Папа",
                             status: "В семье", isCurrentUser: false),
            ])

            func measurement(_ type: MeasurementType, at date: Date, value: Double) -> ChildMeasurement {
                ChildMeasurement(babyID: baby.id, type: type, measuredAt: date, value: value, createdAt: date,
                                 modifiedAt: date)
            }
            try persistence.saveChildProfile(baby, initialMeasurements: [
                measurement(.weight, at: birth, value: 3380),
                measurement(.height, at: birth, value: 51),
                measurement(.headCircumference, at: birth, value: 35),
            ])
            for (daysAgo, weight, height, head) in [
                (78, 4200.0, 54.0, 37.0), (48, 5120, 57.5, 39),
                (19, 5950, 61, 40.5), (3, 6340, 63, 41),
            ] {
                let measured = date(daysAgo: daysAgo, hour: 10)
                try persistence.saveMeasurement(measurement(.weight, at: measured, value: weight))
                try persistence.saveMeasurement(measurement(.height, at: measured, value: height))
                try persistence.saveMeasurement(measurement(.headCircumference, at: measured, value: head))
            }

            let lena = EventAuthor(id: "owner", nameSnapshot: "Лена", role: .mother)
            let misha = EventAuthor(id: "participant-1", nameSnapshot: "Миша", role: .father)
            func event(
                _ kind: EventKind, at start: Date, minutes: Int = 0, author: EventAuthor,
                side: BreastSide = .left, volume: Int = 100, diaper: DiaperType = .wet, recent: Bool = false
            ) throws {
                let end = start.addingTimeInterval(Double(minutes) * 60)
                guard end <= (reminderCapture ? reminderBottle : now) else { return }
                if calendar.isDate(start, inSameDayAs: now), end > now.addingTimeInterval(-3 * 3600), !recent { return }
                let record = CareEvent(
                    babyID: baby.id, kind: kind, start: start, end: end, createdAt: end,
                    side: side, leftSeconds: kind == .breast && side == .left ? Double(minutes * 60) : 0,
                    rightSeconds: kind == .breast && side == .right ? Double(minutes * 60) : 0,
                    volumeML: volume, bottleType: .expressed, diaperType: diaper, createdBy: author
                )
                try record.validate(now: now)
                try persistence.saveEvent(record)
            }

            for day in 0 ... 6 {
                let drift = day * 3
                func at(_ hour: Int, _ minute: Int) -> Date {
                    date(daysAgo: day, hour: hour, minute: minute + drift)
                }
                try event(.sleep, at: at(0, 8), minutes: 252 - drift + (day % 3) * 9, author: misha)
                try event(.breast, at: at(4, 23), minutes: 12 + day % 3, author: lena)
                try event(.sleep, at: at(4, 42), minutes: 143 - drift, author: lena)
                try event(.diaper, at: at(7, 12), author: misha, diaper: .mixed)
                try event(.breast, at: at(7, 23), minutes: 15 - day % 2, author: lena, side: .right)
                try event(.sleep, at: at(8, 35), minutes: 61 + drift, author: misha)
                try event(.bottle, at: at(10, 7), minutes: 13, author: misha, volume: 110 + (day % 3) * 10)
                try event(.diaper, at: at(10, 31), author: misha)
                try event(.sleep, at: at(11, 26), minutes: 88 - drift - (day % 4) * 5, author: lena)
                try event(.breast, at: at(13, 10), minutes: 16, author: lena)
                try event(.diaper, at: at(13, 39), author: lena)
                try event(.sleep, at: at(14, 29), minutes: 53 + drift, author: lena)
                try event(.bottle, at: at(15, 58 - drift), minutes: 12, author: misha, volume: 120 - (day % 2) * 10)
                try event(.diaper, at: at(16, 20), author: misha)
                try event(.breast, at: at(18, 48 - drift), minutes: 13, author: lena, side: .right)
                try event(.sleep, at: at(20, 13), minutes: 155 + drift, author: misha)
                try event(.breast, at: at(23, 11), minutes: 11, author: lena)
                try event(.diaper, at: at(23, 27), author: misha)
            }

            try event(.sleep, at: now.addingTimeInterval(-130 * 60), minutes: 60, author: misha, recent: true)
            try event(.breast, at: now.addingTimeInterval(-55 * 60), minutes: 15, author: lena, side: .right, recent: true)
            try event(.diaper, at: now.addingTimeInterval(-18 * 60), author: misha, recent: true)

            if reminderCapture {
                try event(.bottle, at: reminderBottle, author: misha, volume: 120, recent: true)
            }

            for (index, caption) in ["Плюшевый друг", "Первый мобиль", "Погремушка", "Вечерняя сказка"].enumerated() {
                let capturedAt = date(daysAgo: index / 3 + 2, hour: 16, minute: 21 - index)
                guard let image = UIImage(named: "StorefrontAlbum\(index)"),
                      let jpeg = image.jpegData(compressionQuality: 0.94), let bitmap = image.cgImage
                else { throw CocoaError(.fileReadCorruptFile) }
                let photo = BabyPhoto(
                    babyID: baby.id, capturedAt: capturedAt, addedAt: capturedAt,
                    addedBy: index.isMultiple(of: 2) ? "owner" : "participant-1",
                    pixelWidth: bitmap.width, pixelHeight: bitmap.height,
                    caption: caption, isFavorite: index == 0
                )
                try persistence.savePhoto(photo, imageData: jpeg, thumbnailData: jpeg)
            }
        }
    }
#endif
