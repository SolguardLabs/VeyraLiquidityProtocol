# Documentación técnica

Esta carpeta describe el estado y la operación de Veyra Liquidity Protocol.

- [Arquitectura](./arquitectura.md): límites entre núcleo, periferia y lectura.
- [Modelo económico](./modelo-economico.md): rangos, precio, capital y comisiones.
- [Integración](./integracion.md): ciclo de posición, cotización y cartera.
- [Operaciones](./operaciones.md): validación, configuración y observabilidad.

Las vistas muestran una fotografía de un bloque; cualquier decisión de ejecución
debe aplicar de nuevo plazo, precio y límites de cantidad en la transacción.
