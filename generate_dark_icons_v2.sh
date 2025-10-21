#!/bin/bash

# Enhanced Dark Mode Icon Generator for iOS 18+
# This script creates much more dramatic dark mode variants

ICON_DIR="ios/Runner/Assets.xcassets/AppIcon.appiconset"
DARK_DIR="$ICON_DIR/dark"

# Create dark directory if it doesn't exist
mkdir -p "$DARK_DIR"

echo "🌙 Generating enhanced dark mode iOS icons..."

# Function to create dramatic dark mode icon
create_dark_icon() {
    local input="$1"
    local output="$2"
    local size="$3"
    
    echo "Creating dramatic dark mode for $input..."
    
    # Method 1: Much more dramatic dark mode transformation
    magick "$input" \
        -modulate 60,130,80 \
        -gamma 0.6 \
        -brightness-contrast -25,20 \
        -sigmoidal-contrast 3,50% \
        "$output"
}

# Alternative method for even darker icons
create_very_dark_icon() {
    local input="$1"
    local output="$2"
    
    echo "Creating very dark mode for $input..."
    
    # Method 2: Very dark transformation
    magick "$input" \
        -modulate 50,120,70 \
        -gamma 0.5 \
        -brightness-contrast -35,25 \
        -sigmoidal-contrast 4,40% \
        -level 0%,70% \
        "$output"
}

# Generate dramatic dark mode variants for all key sizes
create_very_dark_icon "$ICON_DIR/Icon-App-1024x1024@1x.png" "$DARK_DIR/Icon-App-1024x1024@1x-dark.png"
create_very_dark_icon "$ICON_DIR/Icon-App-60x60@3x.png" "$DARK_DIR/Icon-App-60x60@3x-dark.png"
create_very_dark_icon "$ICON_DIR/Icon-App-60x60@2x.png" "$DARK_DIR/Icon-App-60x60@2x-dark.png"
create_very_dark_icon "$ICON_DIR/Icon-App-40x40@3x.png" "$DARK_DIR/Icon-App-40x40@3x-dark.png"
create_very_dark_icon "$ICON_DIR/Icon-App-40x40@2x.png" "$DARK_DIR/Icon-App-40x40@2x-dark.png"
create_very_dark_icon "$ICON_DIR/Icon-App-40x40@1x.png" "$DARK_DIR/Icon-App-40x40@1x-dark.png"
create_very_dark_icon "$ICON_DIR/Icon-App-29x29@3x.png" "$DARK_DIR/Icon-App-29x29@3x-dark.png"
create_very_dark_icon "$ICON_DIR/Icon-App-29x29@2x.png" "$DARK_DIR/Icon-App-29x29@2x-dark.png"
create_very_dark_icon "$ICON_DIR/Icon-App-29x29@1x.png" "$DARK_DIR/Icon-App-29x29@1x-dark.png"
create_very_dark_icon "$ICON_DIR/Icon-App-20x20@3x.png" "$DARK_DIR/Icon-App-20x20@3x-dark.png"
create_very_dark_icon "$ICON_DIR/Icon-App-20x20@2x.png" "$DARK_DIR/Icon-App-20x20@2x-dark.png"
create_very_dark_icon "$ICON_DIR/Icon-App-20x20@1x.png" "$DARK_DIR/Icon-App-20x20@1x-dark.png"

# iPad icons
create_very_dark_icon "$ICON_DIR/Icon-App-76x76@2x.png" "$DARK_DIR/Icon-App-76x76@2x-dark.png"
create_very_dark_icon "$ICON_DIR/Icon-App-76x76@1x.png" "$DARK_DIR/Icon-App-76x76@1x-dark.png"
create_very_dark_icon "$ICON_DIR/Icon-App-83.5x83.5@2x.png" "$DARK_DIR/Icon-App-83.5x83.5@2x-dark.png"

echo "✅ Enhanced dark mode icons generated successfully!"
echo "📁 Dark icons saved to: $DARK_DIR"
echo ""
echo "🎨 Enhanced dark mode adjustments applied:"
echo "   - Brightness: -35%"
echo "   - Contrast: +25%"
echo "   - Saturation: -30%"
echo "   - Gamma: 0.5 (much darker shadows)"
echo "   - Sigmoidal contrast: 4,40% (dramatic contrast boost)"
echo "   - Level adjustment: 0%,70% (darken highlights)"
echo ""
echo "📱 These icons will be much more visible in iOS 18+ dark mode!"
