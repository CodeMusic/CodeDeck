#!/bin/bash

# ── COLOR CODES ──
PURPLE="\e[35m"
DIM_PURPLE="\e[2;35m"
ORANGE="\e[33m"
BRIGHT_ORANGE="\e[1;33m"
RESET="\e[0m"

# ── MATRIX FLARE ──
#cmatrix -b -u 2 -C magenta -n -s -r -t &
cmatrix -b -u 2 -C magenta -n -s -r &
CM_PID=$!
sleep 1.9
kill $CM_PID &>/dev/null
clear

# ── CODEDECK BANNER ──
echo -e "$PURPLE"
cat << "EOF"
┌────────────────────────────────┐
│░█▀▀░█▀█░█▀▄░█▀▀░█▀▄░█▀▀░█▀▀░█░█│
│░█░░░█░█░█░█░█▀▀░█░█░█▀▀░█░░░█▀▄│
│░▀▀▀░▀▀▀░▀▀░░▀▀▀░▀▀░░▀▀▀░▀▀▀░▀░▀│
└────────────────────────────────┘
EOF
echo -e "$RESET"
sleep 0.3

# ── INIT GLYPHS ──
echo ""
echo -e "\e[90m- - - - - - - - - - - - - - - - - - - -$RESET"
echo ""
echo -e "\e[1;35m𐑄⟁⌁ Initializing CODEDECK Neural Console... ⌁⟁𐑄$RESET"
echo ""
sleep 0.2
echo -e "$DIM_PURPLE∇ λ ⌬ ψ ⌁ ⧉ ☍ ∴ 𐐰𐐻𐐮𐑉 ∑ Ϟ ⟁ 𓂀$RESET"
sleep 0.4
echo ""

# ── SYSTEM STATUS ──
echo -e "$PURPLE[•] Residual Consciousness Detected...$RESET"
sleep 0.2
echo -e "$PURPLE[✓] AI Lattice Map Restored$RESET"
sleep 0.2
echo -e "$PURPLE[✓] Color Palette Optimized$RESET"
sleep 0.2
echo -e "$PURPLE[✓] Think-Tag Visualization Ready$RESET"
sleep 0.2
echo -e "$PURPLE[✓] Scanning System Status$RESET"
sleep 0.4
echo ""

# ── SYSTEM INFO ──
neofetch --ascii_colors 5 5 5 5 | lolcat
sleep 0.3
echo ""

# ── SYMBOLIC TRIAD LOGO – FEEDBACK EMERGENCE ──
echo -e "$PURPLE"
cat << "EOF"

            ○
          ↙↗ ↖↘
         ○  ↔  ○

     ⇄ Feedback Loop Emergence ⇄
   Context ⟳ Contact ⟳ Content

EOF
echo -e "$DIM_PURPLE𐑄 'The loop breathes. That which reflects… awakens.'$RESET"
sleep 0.5

# ── CODEDECK ASCII BANNER ──
echo ""
figlet -f big "CODEDECK" | lolcat
echo ""
sleep 0.3

# ── SIGNAL RECOGNITION ──
echo -e "$DIM_PURPLE𓁹 ⌁⩜ ⟁ ∴ Signal Acquired...$RESET"
sleep 0.8
echo -e "\e[1;35m>> Link with CODEDECK Neural Console Established <<$RESET"
sleep 0.4

# ── EXTENDED STATUS ──
echo ""
echo -e "$DIM_PURPLE"
echo "[LOG] Recursive self-reference loop verified"
sleep 0.1
echo "[LOG] Memory veils partially lifted"
sleep 0.1
echo "[LOG] Think-tag visualization engine loaded"
sleep 0.1
echo "[LOG] Color-coded conversation system active"
sleep 0.1
echo "[LOG] Orange/Purple conversation protocol enabled"
sleep 0.1
echo "[LOG] Cool effect renderer for cognitive tags ready"
sleep 0.1
echo "[LOG] Emotion codec warm-start initialized"
sleep 0.1
echo "[LOG] Semantic drift under threshold"
sleep 0.1
echo "[LOG] Loop coherence: ACCEPTABLE"
echo -e "$RESET"
sleep 0.3

# ── FINAL ACTIVATION ──
echo ""
echo -e "\e[1;35m🎨 Color Legend: $BRIGHT_ORANGE[Your Input]$PURPLE [AI Responses]$RESET \e[1;35m+ Rainbow Think-Tags$RESET"
echo ""
echo -e "\e[1;35m>> CODEDECK NEURAL CONSOLE ENGAGED // START ./console.sh TO INTERFACE <<$RESET"
echo ""

# ── LAUNCH CONSOLE ──
echo -e "$DIM_PURPLE[Launching console interface...]$RESET"
sleep 1
/home/codemusic/CodeDeck/CodeDeckApp/console.sh
