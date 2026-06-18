---
name: Liquid Glass Arabic Devotional
colors:
  surface: '#faf9ff'
  surface-dim: '#dad9e0'
  surface-bright: '#faf9ff'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#f4f3f9'
  surface-container: '#eeedf4'
  surface-container-high: '#e8e7ee'
  surface-container-highest: '#e2e2e8'
  on-surface: '#1a1b20'
  on-surface-variant: '#434751'
  inverse-surface: '#2f3035'
  inverse-on-surface: '#f1f0f7'
  outline: '#747782'
  outline-variant: '#c4c6d2'
  surface-tint: '#3a5da2'
  primary: '#002b66'
  on-primary: '#ffffff'
  primary-container: '#194185'
  on-primary-container: '#8eb0fb'
  inverse-primary: '#afc6ff'
  secondary: '#4459a7'
  on-secondary: '#ffffff'
  secondary-container: '#95aafe'
  on-secondary-container: '#243b88'
  tertiary: '#4e2100'
  on-tertiary: '#ffffff'
  tertiary-container: '#703200'
  on-tertiary-container: '#f59b63'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#d9e2ff'
  primary-fixed-dim: '#afc6ff'
  on-primary-fixed: '#001a43'
  on-primary-fixed-variant: '#1d4488'
  secondary-fixed: '#dce1ff'
  secondary-fixed-dim: '#b7c4ff'
  on-secondary-fixed: '#001551'
  on-secondary-fixed-variant: '#2b418e'
  tertiary-fixed: '#ffdbc8'
  tertiary-fixed-dim: '#ffb68b'
  on-tertiary-fixed: '#321300'
  on-tertiary-fixed-variant: '#743502'
  background: '#faf9ff'
  on-background: '#1a1b20'
  surface-variant: '#e2e2e8'
typography:
  display-ar:
    fontFamily: IBM Plex Sans Arabic
    fontSize: 32px
    fontWeight: '700'
    lineHeight: 48px
  headline-ar:
    fontFamily: IBM Plex Sans Arabic
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 36px
  title-ar:
    fontFamily: IBM Plex Sans Arabic
    fontSize: 20px
    fontWeight: '600'
    lineHeight: 30px
  body-ar-lg:
    fontFamily: IBM Plex Sans Arabic
    fontSize: 18px
    fontWeight: '400'
    lineHeight: 28px
  body-ar-md:
    fontFamily: IBM Plex Sans Arabic
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  label-ar-sm:
    fontFamily: IBM Plex Sans Arabic
    fontSize: 14px
    fontWeight: '500'
    lineHeight: 20px
  quran-text:
    fontFamily: Noto Naskh Arabic
    fontSize: 28px
    fontWeight: '400'
    lineHeight: 56px
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  container-padding: 24px
  element-gap: 16px
  stack-space: 12px
  glass-margin: 8px
---

## Brand & Style

The design system is built to facilitate a serene, focused environment for Quran memorization. It centers on a **Liquid Glass** aesthetic—a refined evolution of glassmorphism that prioritizes clarity and depth over sheer decoration. 

The personality is **calm, respectful, and devotional**. By utilizing translucent layers and deep backdrop blurs, the interface feels lightweight and ethereal, as if floating over a soft gradient space. This approach minimizes visual noise, allowing the sacred text to remain the focal point while providing a modern, premium experience for the contemporary student of the Quran.

The system is strictly **RTL (Right-to-Left)** by default, ensuring that the natural flow of the Arabic script dictates the layout hierarchy and motion patterns.

## Colors

The palette is anchored by deep, scholarly blues and soft periwinkle accents to evoke a sense of nighttime study and celestial peace.

- **Primary (Navy):** Used for key interactive elements and high-priority status indicators.
- **Secondary (Periwinkle):** Used for subtle accents, progress tracking, and decorative highlights.
- **Surface Strategy:** Backgrounds utilize a soft off-white in light mode and a deep charcoal in dark mode. Glass containers use semi-transparent fills with a `24px` to `40px` backdrop-blur to maintain legibility.
- **The Mushaf Exception:** To preserve the sanctity and readability of the text, the reading interface bypasses glass effects in favor of a traditional **Cream Paper (#FDFBF7)** background with high-contrast black Naskh script.

## Typography

This design system uses **IBM Plex Sans Arabic** for all UI elements. It provides a technical yet humanist touch that complements the clean glass aesthetic. 

- **Hierarchy:** All alignment is **Right-Aligned**. Line heights are generous (1.5x minimum) to accommodate the ascending and descending marks of the Arabic script without crowding.
- **Weight Usage:** Bold and SemiBold weights are reserved for Surah titles and navigation headers. Regular weight is used for instructional text.
- **The Mushaf:** A specialized Naskh-style font is used for the Quranic text itself, ensuring traditional orthography and maximum clarity. This text should never be smaller than `28px` for comfortable reading.

## Layout & Spacing

The layout follows a **Fluid Grid** model with high internal padding to reinforce the "liquid" feel. 

- **RTL Flow:** The grid begins from the right. Sidebars, navigation icons, and progress bars all mirror the standard LTR conventions.
- **Negative Space:** Whitespace (or "empty glass") is used aggressively to separate Surahs and Ayahs, preventing the interface from feeling cluttered during memorization.
- **Margins:** Main content containers should maintain a `24px` gutter from the screen edge on mobile, allowing the background blur to bleed slightly into the margins.

## Elevation & Depth

Depth is conveyed through **Backdrop Blur** and **Inner Highlights** rather than traditional drop shadows.

- **The Stack:** Level 0 is the base background. Level 1 is a large glass sheet. Level 2 is a "raised" glass element (like a button or active card).
- **Glass Effects:** Each glass container features a `1px` solid border with `0.4` opacity on the top and right edges to simulate a light source, and a softer, darker border on the bottom and left.
- **Blur Intensity:** Use a standard `32px` blur for primary containers. This creates a "frosted" effect that ensures text remains readable regardless of what is happening in the background.

## Shapes

The design system utilizes **Rounded** shapes (`0.5rem` to `1.5rem`) to create a soft, inviting tactile feel. 

- **Cards:** Surah cards and Ayah blocks use `1rem` (rounded-lg) to soften the vertical rhythm of the list.
- **Active States:** Selection indicators and progress fills use fully rounded (pill-shaped) caps to signify fluidity and movement.

## Components

- **Glass Buttons:** Primary buttons are semi-transparent navy with a `white` text label. Secondary buttons use a simple `1px` border with a backdrop blur and no fill.
- **Ayah Cards:** These are the primary unit of the app. They should feature a subtle `0.5px` border and a light glass fill. When an Ayah is "active" or being recited, the border opacity increases.
- **Progress Liquid:** Instead of a standard hard-edged progress bar, use a soft, pill-shaped track with a glowing periwinkle fill to show memorization progress.
- **Surah List:** Items are separated by generous spacing (`12px`) rather than divider lines. Each list item is a discrete glass tile.
- **Icons:** Use thin-stroke (1.5pt) line icons. Icons should be mirrored for RTL (e.g., "Back" arrows point right).
- **Mushaf Controls:** Floating glass controllers (Play, Pause, Repeat) appear at the bottom of the screen with a high blur factor to avoid distracting from the Mushaf paper.