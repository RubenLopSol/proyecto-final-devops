#!/bin/bash
# Script para exportar todos los diagramas Mermaid a PNG

set -e

echo "📊 Exportando diagramas Mermaid a PNG..."
echo ""

# Verificar si mmdc está instalado
if ! command -v mmdc &> /dev/null; then
    echo "⚠️  mermaid-cli no está instalado"
    echo "Instalando @mermaid-js/mermaid-cli..."
    npm install -g @mermaid-js/mermaid-cli
    echo ""
fi

# Contador
count=0

# Exportar cada diagrama
for file in *.mmd; do
    if [ -f "$file" ]; then
        output="${file%.mmd}.png"
        echo "  🔄 Exportando: $file → $output"

        mmdc -i "$file" \
             -o "$output" \
             -b transparent \
             -w 2048 \
             -s 2

        count=$((count + 1))
    fi
done

echo ""
echo "✅ Exportación completada! ($count diagramas)"
echo ""
echo "📁 Archivos generados:"
ls -lh *.png 2>/dev/null || echo "  (ninguno)"
echo ""
echo "💡 Tip: Para SVG usa: mmdc -i archivo.mmd -o archivo.svg"
