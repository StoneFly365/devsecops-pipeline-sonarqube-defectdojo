Resumen ejecutivo                                                                                                                                        
                                                                                                                                                           
  WebGoat es una aplicación Java de 11.860 líneas de código diseñada intencionadamente para ser insegura (es una herramienta de formación de OWASP). El    
  análisis ha detectado lo siguiente:                                                                                                                      
                                                                                                                                                           
  ---
  Cifras clave

  ┌─────────────────────────────┬───────────┬─────────────────────────────────────────────────┐
  │          Categoría          │ Resultado │                  Qué significa                  │
  ├─────────────────────────────┼───────────┼─────────────────────────────────────────────────┤
  │ Bugs                        │ 28        │ Errores que pueden causar fallos en producción  │
  ├─────────────────────────────┼───────────┼─────────────────────────────────────────────────┤
  │ Vulnerabilidades            │ 1         │ Fallo de seguridad confirmado y explotable      │
  ├─────────────────────────────┼───────────┼─────────────────────────────────────────────────┤
  │ Security Hotspots           │ 44        │ Código sensible que requiere revisión humana    │
  ├─────────────────────────────┼───────────┼─────────────────────────────────────────────────┤
  │ Code Smells                 │ 318       │ Malas prácticas que dificultan el mantenimiento │
  ├─────────────────────────────┼───────────┼─────────────────────────────────────────────────┤
  │ Issues Críticos/Bloqueantes │ 64        │ Los más urgentes de resolver                    │
  └─────────────────────────────┴───────────┴─────────────────────────────────────────────────┘

  ---
  Seguridad — lo más importante para el cliente

  1 Vulnerabilidad confirmada (BLOCKER)
  - CommentsCache.java:71 — XXE (XML External Entity Injection). El parser XML acepta entidades externas, lo que permite a un atacante leer ficheros del
  servidor o hacer peticiones internas. Es la vulnerabilidad OWASP A4. Solución: deshabilitar acceso a entidades externas en el parser.

  44 Security Hotspots — áreas de riesgo que requieren revisión manual, agrupadas en:

  ┌──────────────────────────────┬─────┬───────────────┐
  │          Categoría           │ Nº  │ Probabilidad  │
  ├──────────────────────────────┼─────┼───────────────┤
  │ Autenticación débil          │ 15  │ HIGH / MEDIUM │
  ├──────────────────────────────┼─────┼───────────────┤
  │ Criptografía débil           │ 11  │ HIGH / MEDIUM │
  ├──────────────────────────────┼─────┼───────────────┤
  │ Inyección SQL                │ 8   │ HIGH          │
  ├──────────────────────────────┼─────┼───────────────┤
  │ Configuración insegura       │ 4   │ MEDIUM        │
  ├──────────────────────────────┼─────┼───────────────┤
  │ Denegación de servicio (DoS) │ 3   │ LOW           │
  └──────────────────────────────┴─────┴───────────────┘

  ▎ La diferencia entre una vulnerabilidad y un hotspot es que la vulnerabilidad SonarQube la certifica como explotable, mientras que los hotspots
  ▎ requieren que un analista humano confirme si son realmente un riesgo en ese contexto concreto.

  ---
  Fiabilidad — los 28 bugs

  La mayoría son del tipo:
  - Recursos no cerrados (Use try-with-resources) — conexiones, streams o ficheros que no se cierran correctamente. En producción esto genera fugas de
  memoria y puede tumbar la aplicación bajo carga.
  - Objetos reutilizables no cacheados (Save and re-use) — objetos costosos que se recrean en cada petición innecesariamente, degradando el rendimiento.

  ---
  Mantenibilidad — los 318 code smells

  Son problemas de calidad de código que no rompen la aplicación hoy pero la hacen más cara de mantener:
  - Literales duplicados (ej. la cadena /login repetida 3 veces en lugar de usar una constante)
  - Métodos vacíos sin comentario explicativo
  - Modificación de variables estáticas desde métodos de instancia (riesgo en entornos multihilo)

  ---
  Mensaje clave para el cliente

  El análisis automatizado ha localizado 1 vulnerabilidad crítica explotable (XXE) y 44 puntos de riesgo de seguridad que deben ser revisados por un especialista antes de llevar este tipo de código a producción. Además, los 28 bugs de fiabilidad representan riesgo operacional real bajo carga. Todo esto se detectó en menos de 1 minuto de análisis sobre el código fuente, sin necesidad de ejecutar la aplicación.