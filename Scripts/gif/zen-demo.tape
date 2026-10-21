Output zen-demo.mp4

Set Shell zsh
Set Width 1600
Set Height 960
Set FontSize 17
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 12ms

Hide
Type "cd /tmp/zen-demo && git reset -q --hard && git clean -qfdx && alias zen='python3 /tmp/zen-demo-rec/director.py' && clear"
Enter
Sleep 1s
Show

Set TypingSpeed 60ms
Type "zen --agent Developer"
Enter
Sleep 4s

Set TypingSpeed 12ms
Type "Add per-product discounts to this Swift package using two Developer sub-agents in parallel. Agent 'model' edits Sources/Shop/Product.swift: add `discount: Double` (0...1, default 0) and a computed `finalPrice`. Agent 'cart' edits Sources/Shop/Cart.swift so `total` sums `finalPrice`, and adds a discount test to Tests/ShopTests/CartTests.swift. Before editing, 'cart' must ask 'model' in the shared chat for the exact API, and 'model' must answer there. Finally run swift test."
Sleep 1500ms
Enter

# director.py opens the shared chat on the first agent message, replies,
# closes it, and exits zen once the turn has finished.
Wait@15m />$/
