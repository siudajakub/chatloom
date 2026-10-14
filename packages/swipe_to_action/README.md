# swipe_to_action

A widget which can be used to call functions when the wrapped child is dragged or flinged. Only intended to work with horizontal swipes.

Features:
- Aware of input type (touch, mouse, stylus), allowed types can be passed.
- Allows calling different functions depending on swipe direction.
- Allows different backgrounds depending on swipe direction.
- Allows calling a confirmation function before calling intended function.

## Getting Started

Import the package

```dart
import 'package:swipe_to_action/swipe_to_action.dart';
```

And use Swipeable class, for example:
```dart
Swipeable(
    key: ValueKey("Some key, required"),
    onSwipe: (direction) {
        if (direction == SwipeDirection.startToEnd) {
            // do something
        } else {
            // do something else
        }
    },
    // Widget to display below.
    // If [secondaryBackground] is defined, only works when swiping from start to end.
    // Optional.
    background: Container(color: Colors.green),
    // Widget to display below if swiping from end to start.
    // Only works if [background] is defined
    // Optional.
    secondaryBackground: Container(color: Colors.teal),
    // Function to call before calling onSwipe. If it returns false,
    // swipe is aborted and onSwipe is not called.
    // Optional.
    confirmSwipe: (direction) async {
        return true;
    },
    // By default swiping works only with touch or stylus. You may alter this
    // by specifying device kinds to use. This is a list of all device kinds.
    allowedPointerKinds = {
      PointerDeviceKind.touch,
      PointerDeviceKind.stylus,
      PointerDeviceKind.invertedStylus,
      PointerDeviceKind.mouse,
      PointerDeviceKind.unknown,
    },

    child: /* required */,
)
```

All arguments are documented: you may refer to IntelliSense, source code or API docs.
