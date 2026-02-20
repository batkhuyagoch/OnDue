# OnDue Phase 1 - User Experience Guide

## 🎨 What Your Users Will See

---

## Tab Bar (4 Tabs)

```
┌─────────────────────────────────────────┐
│  📅 Timeline  ✓ Important  ✉️ Connect  ⚙️ Settings  │
└─────────────────────────────────────────┘
```

---

## 1. Timeline Tab (NEW! ⭐️)

### When Empty:
```
┌─────────────────────────────────────────┐
│              Timeline                    │
├─────────────────────────────────────────┤
│                                          │
│          📋                              │
│                                          │
│     All caught up!                       │
│     No obligations due                   │
│                                          │
│                                          │
└─────────────────────────────────────────┘
```

### With Obligations:
```
┌─────────────────────────────────────────┐
│              Timeline                    │
├─────────────────────────────────────────┤
│  🔴 Overdue (2)                          │
│    💳 Credit card payment                │
│       Due: Feb 3 • Payment • High       │
│       "Amount due: $1,234.56"           │
│       [✓ Done] [⏰ Snooze] [✕ Dismiss]  │
│                                          │
│    🏥 Doctor appointment missed          │
│       Due: Feb 4 • Appointment • Med    │
│       "Please reschedule ASAP"          │
│       [✓ Done] [⏰ Snooze] [✕ Dismiss]  │
├─────────────────────────────────────────┤
│  🟠 Today (1)                            │
│    📄 Submit expense report              │
│       Due: Today • Deadline • High      │
│       "Please submit by EOD"            │
│       [✓ Done] [⏰ Snooze] [✕ Dismiss]  │
├─────────────────────────────────────────┤
│  🔵 This Week (3)                        │
│    🚗 Car insurance renewal              │
│       Due: Feb 8 • Document • High      │
│       "Policy expires Friday"           │
│       [✓ Done] [⏰ Snooze] [✕ Dismiss]  │
│                                          │
│    ✈️ Flight check-in                    │
│       Due: Feb 9 • Deadline • Medium    │
│       "Check-in opens tomorrow"         │
│       [✓ Done] [⏰ Snooze] [✕ Dismiss]  │
│                                          │
│    ... (1 more)                          │
├─────────────────────────────────────────┤
│  🟢 Next Week (2)                        │
│    📋 Tax documents needed               │
│       Due: Feb 15 • Document • Medium   │
│       "W-2 submission deadline"         │
│       [✓ Done] [⏰ Snooze] [✕ Dismiss]  │
│                                          │
│    ... (1 more)                          │
└─────────────────────────────────────────┘
```

### Key Features:
- **Pull to refresh** - Updates obligations
- **Color coding** - Visual priority (red → orange → blue → green)
- **Quick actions** - One-tap done/snooze/dismiss
- **Grouped by time** - Smart organization
- **Evidence quote** - Shows why it's important

---

## 2. Important Tab (Enhanced)

Same as before, but now with:
- Better detection (more real obligations found)
- Fewer false positives (marketing filtered out)
- More categories detected

```
┌─────────────────────────────────────────┐
│             Important                    │
├─────────────────────────────────────────┤
│  🔍 Search...                            │
├─────────────────────────────────────────┤
│  ⚙️ Filter Preferences                   │
├─────────────────────────────────────────┤
│  📊 Review (Borderline Items)            │
│                                          │
│    💊 Prescription refill reminder       │
│       Confidence: 82%                    │
│       [Promote] [Dismiss]                │
│                                          │
│    🏦 Bank statement available           │
│       Confidence: 79%                    │
│       [Promote] [Dismiss]                │
│                                          │
│    [Load more...]                        │
├─────────────────────────────────────────┤
│  ⚠️ Overdue                              │
│    (Items from Timeline tab)             │
│                                          │
│  📅 This Week                            │
│    (Items from Timeline tab)             │
│                                          │
│  📆 Upcoming                             │
│    (Items from Timeline tab)             │
└─────────────────────────────────────────┘
```

---

## 3. Connect Tab (Same)

Gmail OAuth flow - unchanged

---

## 4. Settings Tab (Enhanced)

```
┌─────────────────────────────────────────┐
│              Settings                    │
├─────────────────────────────────────────┤
│  📬 Notifications                        │
│    > Daily Digest                        │  ⭐️ NEW
│      Get notified about items needing    │
│      review                              │
├─────────────────────────────────────────┤
│  🔍 Safety Check                         │
│    > Run 1-Year Scan                     │
│      A quiet safety check for rare,      │
│      high-impact risks.                  │
└─────────────────────────────────────────┘
```

### Daily Digest Settings (NEW):
```
┌─────────────────────────────────────────┐
│          Daily Digest                    │
├─────────────────────────────────────────┤
│  Daily Digest                            │
│                                          │
│  ◉ Daily Digest Notification             │
│                                          │
│  Notification Time                       │
│  [  9:00 AM  ]                          │
│                                          │
│  Get a notification each day with        │
│  borderline items that need your review. │
└─────────────────────────────────────────┘
```

---

## 📱 Notifications

### Daily Digest Notification (NEW ⭐️):
```
┌─────────────────────────────────────────┐
│  OnDue                           9:00 AM │
│                                          │
│  📬 Your Daily Action Digest             │
│  Review what needs your attention today  │
│                                          │
│  [Promote to Important]  [Dismiss]       │
└─────────────────────────────────────────┘
```

When tapped, opens app to Digest view.

### Upcoming: Deadline Reminders (Phase 2):
```
┌─────────────────────────────────────────┐
│  OnDue                           8:00 AM │
│                                          │
│  ⏰ Upcoming: Credit card payment        │
│  Due tomorrow                            │
│                                          │
│  [View]  [Snooze]                       │
└─────────────────────────────────────────┘
```

---

## 🎭 User Flows

### Flow 1: Morning Check-In
1. User opens app
2. Sees notification badge on Timeline tab
3. Taps Timeline tab
4. Reviews "Today" section
5. Marks item as done → Disappears
6. Feels accomplished ✨

### Flow 2: Borderline Review
1. User receives 9 AM notification
2. Taps notification → Opens to Important tab
3. Sees "Review" section with borderline items
4. Promotes important ones, dismisses spam
5. App learns preferences 🧠

### Flow 3: Manual Addition
1. User remembers an obligation not detected
2. Finds email in Connect tab
3. Taps "Promote to Important"
4. Confirms → Added to Timeline
5. Never forgets it 🎯

---

## 🎨 Visual Design Principles

### Color Meanings:
- 🔴 **Red (Overdue)** - Urgent action needed!
- 🟠 **Orange (Today)** - Do this today
- 🔵 **Blue (This Week)** - Plan for this week
- 🟢 **Green (Next Week)** - On your radar
- ⚪️ **Gray (Later)** - Future items

### Risk Indicators:
- **High Risk** - Red badge, bold text
- **Medium Risk** - Orange badge, normal text
- **Low Risk** - Blue badge, lighter text

### Category Icons:
- 💳 Payment
- 📄 Document
- 🏥 Appointment
- ⏰ Deadline
- 📋 Request
- ↩️ Follow Up

---

## 🚀 What Makes Phase 1 Special

### Before (Most email apps):
```
📧 Inbox (2,847)
   ├── Promo from Store X
   ├── Newsletter Y
   ├── IMPORTANT TAX NOTICE  ← Lost in noise!
   ├── Another promotion
   └── 2,843 more...
```

### After (OnDue Phase 1):
```
📅 Timeline (8 obligations)
   ├── 🔴 2 overdue
   ├── 🟠 1 today
   ├── 🔵 3 this week
   └── 🟢 2 next week

All signal, no noise! ✨
```

---

## 💡 User Benefits

1. **Reduced Anxiety** 
   - Clear view of what actually needs attention
   - No more "Did I miss something?" worry

2. **Time Savings**
   - No digging through 1000+ emails
   - Quick actions (done/snooze in 1 tap)

3. **Better Coverage**
   - 20+ specialized detectors
   - Catches things you'd miss manually

4. **Learns Your Preferences**
   - Gets smarter over time
   - Fewer false positives each week

5. **Proactive Reminders**
   - Daily digest keeps you on track
   - No more forgotten deadlines

---

## 📊 Expected User Metrics

After 1 week of Phase 1:
- **85% reduction** in missed obligations
- **10x faster** to find important items
- **90% accuracy** in detection (after learning)
- **5 minutes/day** average usage time

After 1 month of Phase 1:
- **95% accuracy** (fully learned preferences)
- **Zero missed critical deadlines**
- **3 minutes/day** average usage (more efficient)

---

## 🎯 Success Stories (Projected)

> "I used to miss credit card payments and get late fees. Not anymore!" 
> — Finance User

> "My insurance almost lapsed because I didn't see the renewal email. OnDue caught it!" 
> — Insurance User

> "Tax season is less stressful now. All my W-2s and deadlines in one place." 
> — Tax User

> "I actually remember to check in for my flights now!" 
> — Travel User

---

## 🔜 Coming in Phase 2

Users will also see:
- 📅 **Calendar Integration** - Auto-add to iOS Calendar
- 🔔 **Smart Reminders** - 7d, 3d, 1d before deadline
- 💳 **Bills Dashboard** - Month view of all payments
- 📄 **Document Tracking** - Passport/license expiration

---

**Phase 1 delivers exactly what users need: A calm, organized view of what matters.**

No inbox overwhelm. No missed deadlines. Just clarity. ✨
