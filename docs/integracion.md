# Integración

## Crear y administrar una posición

1. Resolver el pool canónico y leer su precio/tick actuales.
2. Elegir ticks ordenados y alineados con el espaciado configurado.
3. Calcular cantidades máximas y un mínimo aceptable para cada activo.
4. Aprobar al gestor únicamente los importes necesarios.
5. Enviar `mint` con destinatario y plazo; registrar el `tokenId` devuelto.
6. Para `increaseLiquidity`, `decreaseLiquidity`, `collect` o `rebalance`, verificar
   titularidad o aprobación del NFT y recalcular límites cerca de la ejecución.

El rebalanceo no elige una estrategia: el integrador decide el rango y los
límites. Un cambio de precio entre lectura y transacción puede hacer revertir
la operación. Ese rechazo es preferible a ejecutar fuera de las restricciones
económicas indicadas por el proveedor.

## Cotización y ejecución

Quoter es una simulación del estado consultado. Router ejecuta un swap real con
límites exact-input o exact-output y destinatario explícito. Una aplicación debe
presentar la comisión, el mínimo recibido o máximo gastado, el plazo y el
precio de referencia antes de solicitar firma.

## Lectura de cartera

`VeyraPortfolioView` se despliega con las direcciones del gestor y de Lens.
`position(tokenId)` devuelve una fila; `batch(tokenIds)` conserva el orden de
entrada. Cada fila incluye `owner`, `pool`, ticks, liquidez, cantidades de
principal y fees observables. Un ID inexistente revierte a través del gestor;
no se devuelve una fila vacía. Paginar listas extensas evita exceder límites
de gas de llamada y tamaño de respuesta RPC.

Las cantidades pueden cambiar antes de que una transacción se confirme. Para
conciliar datos, leer todos los contratos al mismo número de bloque y conservar
ese identificador junto con la instantánea presentada al usuario.
