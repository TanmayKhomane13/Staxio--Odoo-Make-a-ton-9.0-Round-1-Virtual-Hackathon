:root {
  --primary: #0077B6;   /* buttons, active nav, headings */
  --accent: #E9EBFF;    /* selected rows, table badges, highlights (use #1B1B39 text on it) */
  --bg: #EDEDED;        /* page background */
  --surface: #FFFFFF;   /* cards, panels */
  --text: #202020;      /* body text */
  --on-primary: #FFFFFF;
  --border: #DADADA;    /* derived neutral, the only color not from your list */

  --status-accepted: #0C447C;  /* chip bg #E6F1FB */
  --status-preparing: #633806; /* chip bg #FAEEDA */
  --status-ready: #27500A;     /* chip bg #EAF3DE */
  --status-served: #444441;    /* chip bg #F1EFE8 */
  --status-delayed: #791F1F;   /* chip bg #FCEBEB */
}

Rules to keep it professional
Use the 60-30-10 rule. About 60% of the screen is the neutral background and surface, 30% is text and borders, and 10% or less is primary and accent color.
Use the accent for one thing only. Table numbers and highlights are enough, and it shouldn’t also appear on buttons.
Don’t rely on color alone for status. Always pair it with a text label (“Preparing”, “Delayed”), as the chips above do. This helps color-blind users and the dim kitchen screen.
Check contrast. Body text should reach 4.5:1 against its background (WCAG AA). You can test any pair on webaim.org/resources/contrastchecker.
Use one palette across all four interfaces. Differentiate them by layout and density, not by color. The kitchen display can be larger and higher-contrast, and the customer view can be lighter.
Consider a dark mode for the kitchen display. It reduces glare, but skip it for the hackathon unless you have spare time.



Fonts Used & Their Purposes

Inter (Primary / Interface Font)

Where used: Entire application across all views (/login, /pos, /kitchen, /manager).
Purpose: All core UI typography — buttons, inputs, tables, order cards, headings, stats, badges, and the AI Assistant panel.
Weights loaded: 400, 500, 600, 700.

