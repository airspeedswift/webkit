/*
 * Copyright (C) 2005-2025 Apple Inc. All rights reserved.
 * Copyright (C) 2016-2020 Google Inc. All rights reserved.
 * Copyright (C) 2009 Torch Mobile, Inc.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "TransformationMatrix.h"

#include "AffineTransform.h"
#include "FloatQuad.h"
#include "FloatRect.h"
#include "IntRect.h"
#include "LayoutRect.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <float.h>
#include <limits>
#include <wtf/Assertions.h>
#include <wtf/MathExtras.h>
#include <wtf/StdLibExtras.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/TextStream.h>

#include "WebCore-Swift.h"

// scaleNonUniform(), scale3d(), rotate(), rotate3d(), rotateRadians(), translate3d(), skew(), applyPerspective() and
// zoom() each call a Swift entry point. Where one multiplies by a matrix with constant entries, the entries fold there.

namespace WebCore {

//
// Adapted from Matrix Inversion by Richard Carling, Graphics Gems <http://tog.acm.org/GraphicsGems/index.html>.

// EULA: The Graphics Gems code is copyright-protected. In other words, you cannot claim the text of the code
// as your own and resell it. Using the code is permitted in any program, product, or library, non-commercial
// or commercial. Giving credit is not required, though is a nice gesture. The code comes as-is, and if there
// are any flaws or problems with any Gems code, nobody involved with Gems - authors, editors, publishers, or
// webmasters - are to be held responsible. Basically, don't be a jerk, and remember that anything free comes
// with no guarantee.

// A clarification about the storage of matrix elements
//
// This class uses a 2 dimensional array internally to store the elements of the matrix. The first index into
// the array refers to the column that the element lies in; the second index refers to the row.
//
// In other words, this is the layout of the matrix:
//
// | m_matrix[0][0] m_matrix[1][0] m_matrix[2][0] m_matrix[3][0] |
// | m_matrix[0][1] m_matrix[1][1] m_matrix[2][1] m_matrix[3][1] |
// | m_matrix[0][2] m_matrix[1][2] m_matrix[2][2] m_matrix[3][2] |
// | m_matrix[0][3] m_matrix[1][3] m_matrix[2][3] m_matrix[3][3] |

WTF_MAKE_TZONE_ALLOCATED_IMPL(TransformationMatrix);

using Vector4 = std::array<double, 4>;

const TransformationMatrix TransformationMatrix::identity { };

// inverse(original_matrix, inverse_matrix)
//
// calculate the inverse of a 4x4 matrix
//
// -1
// A  = ___1__ adjoint A
//       det A

//  double = determinant2x2(double a, double b, double c, double d)
//
//  calculate the determinant of a 2x2 matrix.

NODELETE static double determinant2x2(double a, double b, double c, double d)
{
    return a * d - b * c;
}

//  double = determinant3x3(a1, a2, a3, b1, b2, b3, c1, c2, c3)
//
//  Calculate the determinant of a 3x3 matrix
//  in the form
//
//      | a1,  b1,  c1 |
//      | a2,  b2,  c2 |
//      | a3,  b3,  c3 |

NODELETE static double determinant3x3(double a1, double a2, double a3, double b1, double b2, double b3, double c1, double c2, double c3)
{
    return a1 * determinant2x2(b2, b3, c2, c3)
         - b1 * determinant2x2(a2, a3, c2, c3)
         + c1 * determinant2x2(a2, a3, b2, b3);
}

//  double = determinant4x4(matrix)
//
//  calculate the determinant of a 4x4 matrix.

NODELETE static double determinant4x4(const TransformationMatrix::Matrix4& m)
{
    // Assign to individual variable names to aid selecting
    // correct elements

    double a1 = m[0][0];
    double b1 = m[0][1];
    double c1 = m[0][2];
    double d1 = m[0][3];

    double a2 = m[1][0];
    double b2 = m[1][1];
    double c2 = m[1][2];
    double d2 = m[1][3];

    double a3 = m[2][0];
    double b3 = m[2][1];
    double c3 = m[2][2];
    double d3 = m[2][3];

    double a4 = m[3][0];
    double b4 = m[3][1];
    double c4 = m[3][2];
    double d4 = m[3][3];

    return a1 * determinant3x3(b2, b3, b4, c2, c3, c4, d2, d3, d4)
         - b1 * determinant3x3(a2, a3, a4, c2, c3, c4, d2, d3, d4)
         + c1 * determinant3x3(a2, a3, a4, b2, b3, b4, d2, d3, d4)
         - d1 * determinant3x3(a2, a3, a4, b2, b3, b4, c2, c3, c4);
}

// Returns false if the matrix is not invertible
static bool inverse(const TransformationMatrix::Matrix4& matrix, TransformationMatrix::Matrix4& result)
{
#if OS(WINDOWS) && CPU(X86_64)
    // One call, with the determinant in Swift too. Computed here, determinant4x4() makes TransformationMatrix::inverse()
    // save and restore all ten of the Windows x64 callee-saved xmm6-xmm15 on every call, including the identity,
    // translation and affine ones, which use two; and kept out of line, it puts a second frame before the Swift.
    return transformationMatrixInverse(matrix, result);
#else
    // Calculate the 4x4 determinant
    // If the determinant is zero,
    // then the inverse matrix is not unique.
    double determinant = determinant4x4(matrix);
    if (!std::isnormal(determinant))
        return false;

    // Scale the adjoint matrix to get the inverse
    double inverseDeterminant = 1 / determinant;

    // Out of line and cold, so that TransformationMatrix::inverse() sets up a stack frame only on the path that calls it.
    [](const TransformationMatrix::Matrix4& matrix, double inverseDeterminant, TransformationMatrix::Matrix4& result) NEVER_INLINE COLD {
        transformationMatrixScaledAdjoint(matrix, inverseDeterminant, result);
    }(matrix, inverseDeterminant, result);
    return true;
#endif
}

// End of code adapted from Matrix Inversion by Richard Carling

// Perform a decomposition on the passed matrix, return false if unsuccessful
// From Graphics Gems: unmatrix.c

// Transpose rotation portion of matrix a, return b
NODELETE static void transposeMatrix4(const TransformationMatrix::Matrix4& a, TransformationMatrix::Matrix4& b)
{
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++)
            b[i][j] = a[j][i];
}

// Multiply a homogeneous point by a matrix and return the transformed point
NODELETE static void v4MulPointByMatrix(const Vector4& p, const TransformationMatrix::Matrix4& m, Vector4& result)
{
    result[0] = (p[0] * m[0][0]) + (p[1] * m[1][0]) +
                (p[2] * m[2][0]) + (p[3] * m[3][0]);
    result[1] = (p[0] * m[0][1]) + (p[1] * m[1][1]) +
                (p[2] * m[2][1]) + (p[3] * m[3][1]);
    result[2] = (p[0] * m[0][2]) + (p[1] * m[1][2]) +
                (p[2] * m[2][2]) + (p[3] * m[3][2]);
    result[3] = (p[0] * m[0][3]) + (p[1] * m[1][3]) +
                (p[2] * m[2][3]) + (p[3] * m[3][3]);
}

double transformationMatrixDeterminant4x4(const TransformationMatrix::Matrix4& m) { return determinant4x4(m); }

static bool decompose2(const TransformationMatrix::Matrix4& matrix, TransformationMatrix::Decomposed2Type& result)
{
    double row0x = matrix[0][0];
    double row0y = matrix[0][1];
    double row1x = matrix[1][0];
    double row1y = matrix[1][1];
    result.translateX = matrix[3][0];
    result.translateY = matrix[3][1];

    // Compute scaling factors.
    result.scaleX = std::hypot(row0x, row0y);
    result.scaleY = std::hypot(row1x, row1y);

    // If determinant is negative, one axis was flipped.
    double determinant = row0x * row1y - row0y * row1x;
    if (determinant < 0) {
        // Flip axis with minimum unit vector dot product.
        if (row0x < row1y)
            result.scaleX = -result.scaleX;
        else
            result.scaleY = -result.scaleY;
    }

    // Renormalize matrix to remove scale.
    if (result.scaleX) {
        row0x *= 1 / result.scaleX;
        row0y *= 1 / result.scaleX;
    }
    if (result.scaleY) {
        row1x *= 1 / result.scaleY;
        row1y *= 1 / result.scaleY;
    }

    // Compute rotation and renormalize matrix.
    result.angle = atan2(row0y, row0x);

    if (result.angle) {
        // Rotate(-angle) = [cos(angle), sin(angle), -sin(angle), cos(angle)]
        //                = [row0x, -row0y, row0y, row0x]
        // Thanks to the normalization above.
        double sn = -row0y;
        double cs = row0x;
        double m11 = row0x, m12 = row0y;
        double m21 = row1x, m22 = row1y;

        row0x = cs * m11 + sn * m21;
        row0y = cs * m12 + sn * m22;
        row1x = -sn * m11 + cs * m21;
        row1y = -sn * m12 + cs * m22;
    }

    result.m11 = row0x;
    result.m12 = row0y;
    result.m21 = row1x;
    result.m22 = row1y;

    // Convert into degrees because our rotation functions expect it.
    result.angle = rad2deg(result.angle);

    return true;
}

// End of Supporting Math Functions

TransformationMatrix::TransformationMatrix(const AffineTransform& t)
{
    setMatrix(t.a(), t.b(), t.c(), t.d(), t.e(), t.f());
}

TransformationMatrix TransformationMatrix::fromQuaternion(const Quaternion& q)
{
    double xx = q.x * q.x;
    double yy = q.y * q.y;
    double zz = q.z * q.z;
    double xz = q.x * q.z;
    double xy = q.x * q.y;
    double yz = q.y * q.z;
    double xw = q.w * q.x;
    double yw = q.w * q.y;
    double zw = q.w * q.z;

    return TransformationMatrix(1 - 2 * (yy + zz), 2 * (xy + zw), 2 * (xz - yw), 0,
        2 * (xy - zw), 1 - 2 * (xx + zz), 2 * (yz + xw), 0,
        2 * (xz + yw), 2 * (yz - xw), 1 - 2 * (xx + yy), 0,
        0, 0, 0, 1);
}


TransformationMatrix TransformationMatrix::fromProjection(double fovUp, double fovDown, double fovLeft, double fovRight, double depthNear, double depthFar)
{
    double upTan = tan(fovUp);
    double downTan = tan(fovDown);
    double leftTan = tan(fovLeft);
    double rightTan = tan(fovRight);
    double xScale = 2.0 / (leftTan + rightTan);
    double yScale = 2.0 / (upTan + downTan);
    double invDepth = 1.0 / (depthNear - depthFar);

    return TransformationMatrix(xScale, 0.0f, 0.0f, 0.0f,
        0.0f, yScale, 0.0f, 0.0f,
        (leftTan - rightTan) * xScale * -0.5, (upTan - downTan) * yScale * 0.5, (depthNear + depthFar) * invDepth, -1.0f,
        0.0f, 0.0f, (2.0f * depthFar * depthNear) * invDepth, 0.0f);
}

TransformationMatrix TransformationMatrix::fromProjection(double fovy, double aspect, double depthNear, double depthFar)
{
    double f = 1.0 / tan(fovy / 2);
    double invDepth = 1.0 / (depthNear - depthFar);

    return TransformationMatrix(f / aspect, 0.0f, 0.0f, 0.0f,
        0.0f, f, 0.0f, 0.0f,
        0.0f, 0.0f, (depthFar + depthNear) * invDepth, -1.0f,
        0.0f, 0.0f, (2.0f * depthFar * depthNear) * invDepth, 0.0f);
}

TransformationMatrix& TransformationMatrix::scale(double s)
{
    return scaleNonUniform(s, s);
}

TransformationMatrix& TransformationMatrix::rotateFromVector(double x, double y)
{
    return rotateRadians(atan2(y, x));
}

TransformationMatrix& TransformationMatrix::flipX()
{
    return scaleNonUniform(-1.0, 1.0);
}

TransformationMatrix& TransformationMatrix::flipY()
{
    return scaleNonUniform(1.0, -1.0);
}

FloatPoint TransformationMatrix::projectPoint(const FloatPoint& p, bool* clamped) const
{
    // This is basically raytracing. We have a point in the destination
    // plane with z=0, and we cast a ray parallel to the z-axis from that
    // point to find the z-position at which it intersects the z=0 plane
    // with the transform applied. Once we have that point we apply the
    // inverse transform to find the corresponding point in the source
    // space.
    //
    // Given a plane with normal Pn, and a ray starting at point R0 and
    // with direction defined by the vector Rd, we can find the
    // intersection point as a distance d from R0 in units of Rd by:
    //
    // d = -dot (Pn', R0) / dot (Pn', Rd)
    if (clamped)
        *clamped = false;

    if (m33() == 0) {
        // In this case, the projection plane is parallel to the ray we are trying to
        // trace, and there is no well-defined value for the projection.
        return FloatPoint();
    }

    double x = p.x();
    double y = p.y();
    double z = -(m13() * x + m23() * y + m43()) / m33();

    // FIXME: use multVecMatrix()
    double outX = x * m11() + y * m21() + z * m31() + m41();
    double outY = x * m12() + y * m22() + z * m32() + m42();

    double w = x * m14() + y * m24() + z * m34() + m44();
    if (w <= 0) {
        // Using int max causes overflow when other code uses the projected point. To
        // represent infinity yet reduce the risk of overflow, we use a large but
        // not-too-large number here when clamping.
        const int largeNumber = 100000000 / kFixedPointDenominator;
        outX = copysign(largeNumber, outX);
        outY = copysign(largeNumber, outY);
        if (clamped)
            *clamped = true;
    } else if (w != 1) {
        outX /= w;
        outY /= w;
    }

    return FloatPoint(static_cast<float>(outX), static_cast<float>(outY));
}

FloatQuad TransformationMatrix::projectQuad(const FloatQuad& q, bool* clamped) const
{
    FloatQuad projectedQuad;

    bool clamped1 = false;
    bool clamped2 = false;
    bool clamped3 = false;
    bool clamped4 = false;

    projectedQuad.setP1(projectPoint(q.p1(), &clamped1));
    projectedQuad.setP2(projectPoint(q.p2(), &clamped2));
    projectedQuad.setP3(projectPoint(q.p3(), &clamped3));
    projectedQuad.setP4(projectPoint(q.p4(), &clamped4));

    if (clamped)
        *clamped = clamped1 || clamped2 || clamped3 || clamped4;

    // If all points on the quad had w < 0, then the entire quad would not be visible to the projected surface.
    bool everythingWasClipped = clamped1 && clamped2 && clamped3 && clamped4;
    if (everythingWasClipped)
        return FloatQuad();

    return projectedQuad;
}

NODELETE static float clampEdgeValue(double value)
{
    ASSERT(!std::isnan(value));
    const double maxEdgeValue = (LayoutUnit::max() / 2).toDouble();
    return std::clamp(value, -maxEdgeValue, maxEdgeValue);
}

LayoutRect TransformationMatrix::clampedBoundsOfProjectedQuad(const FloatQuad& q) const
{
    if (!m33())
        return { };

    struct HomogeneousPoint {
        double x { 0.0 };
        double y { 0.0 };
        double w { 0.0 };
    };

    auto project = [&](const FloatPoint& p) -> HomogeneousPoint {
        double x = p.x();
        double y = p.y();
        double z = -(m13() * x + m23() * y + m43()) / m33();
        return {
            x * m11() + y * m21() + z * m31() + m41(),
            x * m12() + y * m22() + z * m32() + m42(),
            x * m14() + y * m24() + z * m34() + m44()
        };
    };

    const std::array<HomogeneousPoint, 4> vertices { project(q.p1()), project(q.p2()), project(q.p3()), project(q.p4()) };
    const double minW = std::numeric_limits<float>::epsilon();

    double minX = std::numeric_limits<double>::infinity();
    double minY = std::numeric_limits<double>::infinity();
    double maxX = -std::numeric_limits<double>::infinity();
    double maxY = -std::numeric_limits<double>::infinity();
    auto include = [&](const HomogeneousPoint& p) {
        minX = std::min(minX, p.x / p.w);
        minY = std::min(minY, p.y / p.w);
        maxX = std::max(maxX, p.x / p.w);
        maxY = std::max(maxY, p.y / p.w);
    };

    for (size_t i = 0; i < vertices.size(); ++i) {
        const auto& p = vertices[i];
        const auto& next = vertices[(i + 1) % vertices.size()];
        if (p.w >= minW)
            include(p);
        if ((p.w >= minW) != (next.w >= minW)) {
            const double t = (minW - p.w) / (next.w - p.w);
            include({ p.x + t * (next.x - p.x), p.y + t * (next.y - p.y), minW });
        }
    }

    // A quad entirely behind the eye is not visible.
    if (minX > maxX)
        return { };

    float left = clampEdgeValue(std::floor(minX));
    float top = clampEdgeValue(std::floor(minY));
    float right = clampEdgeValue(std::ceil(maxX));
    float bottom = clampEdgeValue(std::ceil(maxY));
    return LayoutRect(LayoutUnit::clamp(left), LayoutUnit::clamp(top), LayoutUnit::clamp(right - left), LayoutUnit::clamp(bottom - top));
}

void TransformationMatrix::map4ComponentPoint(double& x, double& y, double& z, double& w) const
{
    if (isIdentityOrTranslation()) {
        x += w * m_matrix[3][0];
        y += w * m_matrix[3][1];
        z += w * m_matrix[3][2];
        return;
    }

    Vector4 input = { x, y, z, w };
    Vector4 result;
    v4MulPointByMatrix(input, m_matrix, result);

    x = result[0];
    y = result[1];
    z = result[2];
    w = result[3];
}

FloatPoint TransformationMatrix::mapPoint(const FloatPoint& p) const
{
    if (isIdentityOrTranslation())
        return FloatPoint(p.x() + static_cast<float>(m_matrix[3][0]), p.y() + static_cast<float>(m_matrix[3][1]));

    return internalMapPoint(p);
}

FloatPoint3D TransformationMatrix::mapPoint(const FloatPoint3D& p) const
{
    if (isIdentityOrTranslation())
        return FloatPoint3D(p.x() + static_cast<float>(m_matrix[3][0]),
                            p.y() + static_cast<float>(m_matrix[3][1]),
                            p.z() + static_cast<float>(m_matrix[3][2]));

    return internalMapPoint(p);
}

IntRect TransformationMatrix::mapRect(const IntRect &rect) const
{
    return enclosingIntRect(mapRect(FloatRect(rect)));
}

LayoutRect TransformationMatrix::mapRect(const LayoutRect& r) const
{
    // FIXME: Remove suppression once rdar://189998444 is fixed.
    SUPPRESS_MEMORY_UNSAFE_CAST return enclosingLayoutRect(mapRect(FloatRect(r)));
}

FloatRect TransformationMatrix::mapRect(const FloatRect& r) const
{
    auto type = this->type();
    if (type == Type::IdentityOrTranslation) {
        FloatRect mappedRect(r);
        mappedRect.move(static_cast<float>(m_matrix[3][0]), static_cast<float>(m_matrix[3][1]));
        return mappedRect;
    }

    float minX = r.x();
    float minY = r.y();
    float maxX = r.maxX();
    float maxY = r.maxY();

    if (type == Type::Affine) {
        double a = m11();
        double b = m12();
        double c = m21();
        double d = m22();

        double minResultX;
        double minResultY;
        double maxResultX;
        double maxResultY;

        if (a > 0) {
            maxResultX = a * maxX;
            minResultX = a * minX;
        } else {
            maxResultX = a * minX;
            minResultX = a * maxX;
        }

        if (b > 0) {
            maxResultY = b * maxX;
            minResultY = b * minX;
        } else {
            maxResultY = b * minX;
            minResultY = b * maxX;
        }

        if (c > 0) {
            maxResultX += c * maxY;
            minResultX += c * minY;
        } else {
            maxResultX += c * minY;
            minResultX += c * maxY;
        }

        if (d > 0) {
            maxResultY += d * maxY;
            minResultY += d * minY;
        } else {
            maxResultY += d * minY;
            minResultY += d * maxY;
        }

        return FloatRect(minResultX + m41(), minResultY + m42(), maxResultX - minResultX, maxResultY - minResultY);
    }

    FloatQuad result;

    result.setP1(internalMapPoint(FloatPoint(minX, minY)));
    result.setP2(internalMapPoint(FloatPoint(maxX, minY)));
    result.setP3(internalMapPoint(FloatPoint(maxX, maxY)));
    result.setP4(internalMapPoint(FloatPoint(minX, maxY)));

    return result.boundingBox();
}

FloatQuad TransformationMatrix::mapQuad(const FloatQuad& q) const
{
    if (isIdentityOrTranslation()) {
        FloatQuad mappedQuad(q);
        mappedQuad.move(static_cast<float>(m_matrix[3][0]), static_cast<float>(m_matrix[3][1]));
        return mappedQuad;
    }

    FloatQuad result;
    result.setP1(internalMapPoint(q.p1()));
    result.setP2(internalMapPoint(q.p2()));
    result.setP3(internalMapPoint(q.p3()));
    result.setP4(internalMapPoint(q.p4()));
    return result;
}

TransformationMatrix& TransformationMatrix::scaleNonUniform(double sx, double sy)
{
    transformationMatrixScaleNonUniform(*this, sx, sy);
    return *this;
}

TransformationMatrix& TransformationMatrix::scale3d(double sx, double sy, double sz)
{
    transformationMatrixScale3d(*this, sx, sy, sz);
    return *this;
}

NODELETE static double roundEpsilonToZero(double val)
{
    if (-DBL_EPSILON < val && val < DBL_EPSILON)
        return 0.0;
    return val;
}

TransformationMatrix& TransformationMatrix::rotate3d(double x, double y, double z, double angle, RotationSnapping snapping)
{
    transformationMatrixRotate3d(*this, x, y, z, angle, snapping == RotationSnapping::Snap90degRotations);
    return *this;
}

TransformationMatrix& TransformationMatrix::rotate(double angle, RotationSnapping snapping)
{
    transformationMatrixRotate(*this, angle, snapping == RotationSnapping::Snap90degRotations);
    return *this;
}

TransformationMatrix& TransformationMatrix::rotateRadians(double angle, RotationSnapping snapping)
{
    transformationMatrixRotateRadians(*this, angle, snapping == RotationSnapping::Snap90degRotations);
    return *this;
}

TransformationMatrix& TransformationMatrix::rotate3d(double rx, double ry, double rz, RotationSnapping snapping)
{
    // Angles are in degrees. Switch to radians.
    rx = deg2rad(rx);
    ry = deg2rad(ry);
    rz = deg2rad(rz);

    TransformationMatrix mat;

    double sinTheta = snapping == RotationSnapping::Snap90degRotations ? roundEpsilonToZero(sin(rz)) : sin(rz);
    double cosTheta = snapping == RotationSnapping::Snap90degRotations ? roundEpsilonToZero(cos(rz)) : cos(rz);

    mat.m_matrix[0][0] = cosTheta;
    mat.m_matrix[0][1] = sinTheta;
    mat.m_matrix[0][2] = 0.0;
    mat.m_matrix[1][0] = -sinTheta;
    mat.m_matrix[1][1] = cosTheta;
    mat.m_matrix[1][2] = 0.0;
    mat.m_matrix[2][0] = 0.0;
    mat.m_matrix[2][1] = 0.0;
    mat.m_matrix[2][2] = 1.0;
    mat.m_matrix[0][3] = mat.m_matrix[1][3] = mat.m_matrix[2][3] = 0.0;
    mat.m_matrix[3][0] = mat.m_matrix[3][1] = mat.m_matrix[3][2] = 0.0;
    mat.m_matrix[3][3] = 1.0;

    TransformationMatrix rmat(mat);

    sinTheta = snapping == RotationSnapping::Snap90degRotations ? roundEpsilonToZero(sin(ry)) : sin(ry);
    cosTheta = snapping == RotationSnapping::Snap90degRotations ? roundEpsilonToZero(cos(ry)) : cos(ry);

    transformationMatrixRotateY(rmat, sinTheta, cosTheta);

    sinTheta = snapping == RotationSnapping::Snap90degRotations ? roundEpsilonToZero(sin(rx)) : sin(rx);
    cosTheta = snapping == RotationSnapping::Snap90degRotations ? roundEpsilonToZero(cos(rx)) : cos(rx);

    transformationMatrixRotateX(rmat, sinTheta, cosTheta);

    multiply(rmat);
    return *this;
}

TransformationMatrix& TransformationMatrix::translate(double tx, double ty)
{
    m_matrix[3][0] += tx * m_matrix[0][0] + ty * m_matrix[1][0];
    m_matrix[3][1] += tx * m_matrix[0][1] + ty * m_matrix[1][1];
    m_matrix[3][2] += tx * m_matrix[0][2] + ty * m_matrix[1][2];
    m_matrix[3][3] += tx * m_matrix[0][3] + ty * m_matrix[1][3];
    return *this;
}

TransformationMatrix& TransformationMatrix::translate3d(double tx, double ty, double tz)
{
    transformationMatrixTranslate3d(*this, tx, ty, tz);
    return *this;
}

TransformationMatrix& TransformationMatrix::translateRight(double tx, double ty)
{
    if (tx != 0) {
        m_matrix[0][0] +=  m_matrix[0][3] * tx;
        m_matrix[1][0] +=  m_matrix[1][3] * tx;
        m_matrix[2][0] +=  m_matrix[2][3] * tx;
        m_matrix[3][0] +=  m_matrix[3][3] * tx;
    }

    if (ty != 0) {
        m_matrix[0][1] +=  m_matrix[0][3] * ty;
        m_matrix[1][1] +=  m_matrix[1][3] * ty;
        m_matrix[2][1] +=  m_matrix[2][3] * ty;
        m_matrix[3][1] +=  m_matrix[3][3] * ty;
    }

    return *this;
}

TransformationMatrix& TransformationMatrix::translateRight3d(double tx, double ty, double tz)
{
    translateRight(tx, ty);
    if (tz != 0) {
        m_matrix[0][2] +=  m_matrix[0][3] * tz;
        m_matrix[1][2] +=  m_matrix[1][3] * tz;
        m_matrix[2][2] +=  m_matrix[2][3] * tz;
        m_matrix[3][2] +=  m_matrix[3][3] * tz;
    }

    return *this;
}

TransformationMatrix& TransformationMatrix::skew(double sx, double sy)
{
    transformationMatrixSkew(*this, sx, sy);
    return *this;
}

TransformationMatrix& TransformationMatrix::applyPerspective(double p)
{
    transformationMatrixApplyPerspective(*this, p);
    return *this;
}

TransformationMatrix TransformationMatrix::rectToRect(const FloatRect& from, const FloatRect& to)
{
    ASSERT(!from.isEmpty());
    return TransformationMatrix(to.width() / from.width(),
                                0, 0,
                                to.height() / from.height(),
                                to.x() - from.x(),
                                to.y() - from.y());
}

TransformationMatrix& TransformationMatrix::zoom(double zoomFactor)
{
    transformationMatrixZoom(*this, zoomFactor);
    return *this;
}

TransformationMatrix& TransformationMatrix::unzoom(double zoomFactor)
{
    m_matrix[0][3] *= zoomFactor;
    m_matrix[1][3] *= zoomFactor;
    m_matrix[2][3] *= zoomFactor;
    m_matrix[3][0] /= zoomFactor;
    m_matrix[3][1] /= zoomFactor;
    m_matrix[3][2] /= zoomFactor;
    return *this;
}

// this = mat * this.
TransformationMatrix& TransformationMatrix::multiply(const TransformationMatrix& mat)
{
    transformationMatrixMultiply(*this, mat);
    return *this;
}

TransformationMatrix& TransformationMatrix::multiplyAffineTransform(const AffineTransform& matrix)
{
    if (matrix.isIdentity())
        return *this;

    if (matrix.isIdentityOrTranslation())
        return translate(matrix.e(), matrix.f());

    return multiply(matrix.toTransformationMatrix());
}

void TransformationMatrix::multVecMatrix(double x, double y, double& resultX, double& resultY) const
{
    resultX = m_matrix[3][0] + x * m_matrix[0][0] + y * m_matrix[1][0];
    resultY = m_matrix[3][1] + x * m_matrix[0][1] + y * m_matrix[1][1];
    double w = m_matrix[3][3] + x * m_matrix[0][3] + y * m_matrix[1][3];
    if (w != 1 && w != 0) {
        resultX /= w;
        resultY /= w;
    }
}

void TransformationMatrix::multVecMatrix(double x, double y, double z, double& resultX, double& resultY, double& resultZ) const
{
    resultX = m_matrix[3][0] + x * m_matrix[0][0] + y * m_matrix[1][0] + z * m_matrix[2][0];
    resultY = m_matrix[3][1] + x * m_matrix[0][1] + y * m_matrix[1][1] + z * m_matrix[2][1];
    resultZ = m_matrix[3][2] + x * m_matrix[0][2] + y * m_matrix[1][2] + z * m_matrix[2][2];
    double w = m_matrix[3][3] + x * m_matrix[0][3] + y * m_matrix[1][3] + z * m_matrix[2][3];
    if (w != 1 && w != 0) {
        resultX /= w;
        resultY /= w;
        resultZ /= w;
    }
}

bool TransformationMatrix::isInvertible() const
{
    auto type = this->type();
    if (type == Type::IdentityOrTranslation)
        return true;

    return std::isnormal(type == Type::Affine ? (m11() * m22() - m12() * m21()) : WebCore::determinant4x4(m_matrix));
}

std::optional<TransformationMatrix> TransformationMatrix::inverse() const
{
    auto type = this->type();
    if (type == Type::IdentityOrTranslation) {
        // identity matrix
        if (m_matrix[3][0] == 0 && m_matrix[3][1] == 0 && m_matrix[3][2] == 0)
            return TransformationMatrix();

        // translation
        return TransformationMatrix(1, 0, 0, 0,
                                    0, 1, 0, 0,
                                    0, 0, 1, 0,
                                    -m_matrix[3][0], -m_matrix[3][1], -m_matrix[3][2], 1);
    }

    if (type == Type::Affine) {
        double a = m11();
        double b = m12();
        double c = m21();
        double d = m22();
        double e = m41();
        double f = m42();
        double determinant = a * d - b * c;
        if (!std::isnormal(determinant))
            return std::nullopt;

        double inverseDeterminant = 1 / determinant;
        return {{
            d * inverseDeterminant,
            -b * inverseDeterminant,
            -c * inverseDeterminant,
            a * inverseDeterminant,
            (c * f - d * e) * inverseDeterminant,
            (b * e - a * f) * inverseDeterminant
        }};
    }

    TransformationMatrix invMat;
    // FIXME: Use LU decomposition to apply the inverse instead of calculating the inverse explicitly.
    // Calculating the inverse of a 4x4 matrix using cofactors is numerically unstable and unnecessary to apply the inverse transformation to a point.
    if (!WebCore::inverse(m_matrix, invMat.m_matrix))
        return std::nullopt;

    return invMat;
}

void TransformationMatrix::makeAffine()
{
    m_matrix[0][2] = 0;
    m_matrix[0][3] = 0;

    m_matrix[1][2] = 0;
    m_matrix[1][3] = 0;

    m_matrix[2][0] = 0;
    m_matrix[2][1] = 0;
    m_matrix[2][2] = 1;
    m_matrix[2][3] = 0;

    m_matrix[3][2] = 0;
    m_matrix[3][3] = 1;
}

void TransformationMatrix::flatten()
{
    m_matrix[0][2] = 0;

    m_matrix[1][2] = 0;

    m_matrix[2][0] = 0;
    m_matrix[2][1] = 0;
    m_matrix[2][2] = 1;
    m_matrix[2][3] = 0;

    m_matrix[3][2] = 0;
}

AffineTransform TransformationMatrix::toAffineTransform() const
{
    return AffineTransform(m_matrix[0][0], m_matrix[0][1], m_matrix[1][0],
                           m_matrix[1][1], m_matrix[3][0], m_matrix[3][1]);
}

auto TransformationMatrix::ipcData() const -> IPCData
{
    if (isIdentity())
        return std::monostate { };

    if (isIdentityOrTranslation()) {
        if (!m43())
            return Translation2DIPCData { m41(), m42() };
        return Translation3DIPCData { m41(), m42(), m43() };
    }

    if (isAffine())
        return toAffineTransform();

    return FullIPCData { { {
        m11(), m12(), m13(), m14(),
        m21(), m22(), m23(), m24(),
        m31(), m32(), m33(), m34(),
        m41(), m42(), m43(), m44(),
    } } };
}

TransformationMatrix TransformationMatrix::fromIPCData(IPCData&& data)
{
    return WTF::switchOn(WTF::move(data),
        [] (std::monostate) {
            return TransformationMatrix { };
        }, [] (const Translation2DIPCData& translation) {
            TransformationMatrix matrix;
            matrix.setM41(translation.m41);
            matrix.setM42(translation.m42);
            return matrix;
        }, [] (const Translation3DIPCData& translation) {
            TransformationMatrix matrix;
            matrix.setM41(translation.m41);
            matrix.setM42(translation.m42);
            matrix.setM43(translation.m43);
            return matrix;
        }, [] (const AffineTransform& affineTransform) {
            return TransformationMatrix { affineTransform };
        }, [] (const FullIPCData& full) {
            auto& values = full.values;
            return TransformationMatrix {
                values[0], values[1], values[2], values[3],
                values[4], values[5], values[6], values[7],
                values[8], values[9], values[10], values[11],
                values[12], values[13], values[14], values[15]
            };
        });
}

NODELETE static inline void blendFloat(double& from, double to, double progress, CompositeOperation compositeOperation)
{
    switch (compositeOperation) {
    case CompositeOperation::Replace:
        from = from + (to - from) * progress;
        break;
    case CompositeOperation::Accumulate:
        ASSERT(progress == 1.0);
        from += to - 1;
        break;
    case CompositeOperation::Add:
        ASSERT(progress == 1.0);
        from += to;
        break;
    }
}

void TransformationMatrix::blend2(const TransformationMatrix& from, double progress, CompositeOperation compositeOperation)
{
    Decomposed2Type fromDecomp;
    Decomposed2Type toDecomp;
    if (!from.decompose2(fromDecomp) || !decompose2(toDecomp)) {
        if (progress < 0.5)
            *this = from;
        return;
    }

    // If x-axis of one is flipped, and y-axis of the other, convert to an unflipped rotation.
    if ((fromDecomp.scaleX < 0 && toDecomp.scaleY < 0) || (fromDecomp.scaleY < 0 && toDecomp.scaleX < 0)) {
        fromDecomp.scaleX = -fromDecomp.scaleX;
        fromDecomp.scaleY = -fromDecomp.scaleY;
        fromDecomp.angle += fromDecomp.angle < 0 ? 180 : -180;
    }

    // Don't rotate the long way around.
    if (!fromDecomp.angle)
        fromDecomp.angle = 360;
    if (!toDecomp.angle)
        toDecomp.angle = 360;

    if (std::abs(fromDecomp.angle - toDecomp.angle) > 180) {
        if (fromDecomp.angle > toDecomp.angle)
            fromDecomp.angle -= 360;
        else
            toDecomp.angle -= 360;
    }
    
    // When compositeOperation is accumulate, if the decomposed function is a 1-based value (for affine matrix these properties are
    // m11, m22, scaleX and scaleY), use one based accumulation. Otherwise, use behavior for add.
    auto operationForNonOneBasedValues = compositeOperation == CompositeOperation::Accumulate ? CompositeOperation::Add : compositeOperation;
    blendFloat(fromDecomp.m11, toDecomp.m11, progress, compositeOperation);
    blendFloat(fromDecomp.m12, toDecomp.m12, progress, operationForNonOneBasedValues);
    blendFloat(fromDecomp.m21, toDecomp.m21, progress, operationForNonOneBasedValues);
    blendFloat(fromDecomp.m22, toDecomp.m22, progress, compositeOperation);
    blendFloat(fromDecomp.translateX, toDecomp.translateX, progress, operationForNonOneBasedValues);
    blendFloat(fromDecomp.translateY, toDecomp.translateY, progress, operationForNonOneBasedValues);
    blendFloat(fromDecomp.scaleX, toDecomp.scaleX, progress, compositeOperation);
    blendFloat(fromDecomp.scaleY, toDecomp.scaleY, progress, compositeOperation);
    blendFloat(fromDecomp.angle, toDecomp.angle, progress, operationForNonOneBasedValues);
    recompose2(fromDecomp);
}

void TransformationMatrix::blend4(const TransformationMatrix& from, double progress, CompositeOperation compositeOperation)
{
    Decomposed4Type fromDecomp;
    Decomposed4Type toDecomp;
    if (!from.decompose4(fromDecomp) || !decompose4(toDecomp)) {
        if (progress < 0.5)
            *this = from;
        return;
    }
    
    // When compositeOperation is accumulate, if the decomposed function is a 1-based value (for non-affine matrix these properties are
    // scaleX, scaleY, scaleZ, and perspectiveW), use one based accumulation. Otherwise, use behavior for add.
    auto operationForNonOneBasedValues = compositeOperation == CompositeOperation::Accumulate ? CompositeOperation::Add : compositeOperation;

    blendFloat(fromDecomp.scaleX, toDecomp.scaleX, progress, compositeOperation);
    blendFloat(fromDecomp.scaleY, toDecomp.scaleY, progress, compositeOperation);
    blendFloat(fromDecomp.scaleZ, toDecomp.scaleZ, progress, compositeOperation);
    blendFloat(fromDecomp.skewXY, toDecomp.skewXY, progress, operationForNonOneBasedValues);
    blendFloat(fromDecomp.skewXZ, toDecomp.skewXZ, progress, operationForNonOneBasedValues);
    blendFloat(fromDecomp.skewYZ, toDecomp.skewYZ, progress, operationForNonOneBasedValues);
    blendFloat(fromDecomp.translateX, toDecomp.translateX, progress, operationForNonOneBasedValues);
    blendFloat(fromDecomp.translateY, toDecomp.translateY, progress, operationForNonOneBasedValues);
    blendFloat(fromDecomp.translateZ, toDecomp.translateZ, progress, operationForNonOneBasedValues);
    blendFloat(fromDecomp.perspectiveX, toDecomp.perspectiveX, progress, operationForNonOneBasedValues);
    blendFloat(fromDecomp.perspectiveY, toDecomp.perspectiveY, progress, operationForNonOneBasedValues);
    blendFloat(fromDecomp.perspectiveZ, toDecomp.perspectiveZ, progress, operationForNonOneBasedValues);
    blendFloat(fromDecomp.perspectiveW, toDecomp.perspectiveW, progress, compositeOperation);
    fromDecomp.quaternion = fromDecomp.quaternion.interpolate(toDecomp.quaternion, progress, compositeOperation);

    recompose4(fromDecomp);
}

void TransformationMatrix::blend(const TransformationMatrix& from, double progress, CompositeOperation compositeOperation)
{
    
    if (!progress && compositeOperation == CompositeOperation::Replace) {
        *this = from;
        return;
    }

    if (progress == 1 && compositeOperation == CompositeOperation::Replace)
        return;

    if (from.isIdentity() && isIdentity())
        return;

    if (from.isAffine() && isAffine())
        blend2(from, progress, compositeOperation);
    else
        blend4(from, progress, compositeOperation);
}

bool TransformationMatrix::decompose2(Decomposed2Type& decomp) const
{
    if (isIdentity()) {
        zeroBytes(decomp);
        decomp.scaleX = 1;
        decomp.scaleY = 1;
        decomp.m11 = 1;
        decomp.m22 = 1;
        return true;
    }

    return WebCore::decompose2(m_matrix, decomp);
}

bool TransformationMatrix::decompose4(Decomposed4Type& decomp) const
{
    return transformationMatrixDecompose4(*this, decomp);
}

void TransformationMatrix::recompose2(const Decomposed2Type& decomp)
{
    makeIdentity();

    m_matrix[0][0] = decomp.m11;
    m_matrix[0][1] = decomp.m12;
    m_matrix[1][0] = decomp.m21;
    m_matrix[1][1] = decomp.m22;

    translateRight(decomp.translateX, decomp.translateY);
    rotate(decomp.angle);
    scale3d(decomp.scaleX, decomp.scaleY, 1);
}

void TransformationMatrix::recompose4(const Decomposed4Type& decomp)
{
    makeIdentity();

    // First apply perspective.
    m_matrix[0][3] = decomp.perspectiveX;
    m_matrix[1][3] = decomp.perspectiveY;
    m_matrix[2][3] = decomp.perspectiveZ;
    m_matrix[3][3] = decomp.perspectiveW;

    // Next, translate.
    translate3d(decomp.translateX, decomp.translateY, decomp.translateZ);

    // Apply rotation.
    TransformationMatrix rotationMatrix = TransformationMatrix::fromQuaternion(decomp.quaternion);

    multiply(rotationMatrix);

    // Apply skew.
    if (decomp.skewYZ) {
        TransformationMatrix tmp;
        tmp.setM32(decomp.skewYZ);
        multiply(tmp);
    }

    if (decomp.skewXZ) {
        TransformationMatrix tmp;
        tmp.setM31(decomp.skewXZ);
        multiply(tmp);
    }

    if (decomp.skewXY) {
        TransformationMatrix tmp;
        tmp.setM21(decomp.skewXY);
        multiply(tmp);
    }

    // Finally, apply scale.
    scale3d(decomp.scaleX, decomp.scaleY, decomp.scaleZ);
}

bool TransformationMatrix::isIntegerTranslation() const
{
    if (!isIdentityOrTranslation())
        return false;

    // Check for translate Z.
    if (m_matrix[3][2])
        return false;

    // Check for non-integer translate X/Y.
    if (static_cast<int>(m_matrix[3][0]) != m_matrix[3][0] || static_cast<int>(m_matrix[3][1]) != m_matrix[3][1])
        return false;

    return true;
}

bool TransformationMatrix::containsOnlyFiniteValues() const
{
    return std::isfinite(m_matrix[0][0]) && std::isfinite(m_matrix[0][1]) && std::isfinite(m_matrix[0][2]) && std::isfinite(m_matrix[0][3])
        && std::isfinite(m_matrix[1][0]) && std::isfinite(m_matrix[1][1]) && std::isfinite(m_matrix[1][2]) && std::isfinite(m_matrix[1][3])
        && std::isfinite(m_matrix[2][0]) && std::isfinite(m_matrix[2][1]) && std::isfinite(m_matrix[2][2]) && std::isfinite(m_matrix[2][3])
        && std::isfinite(m_matrix[3][0]) && std::isfinite(m_matrix[3][1]) && std::isfinite(m_matrix[3][2]) && std::isfinite(m_matrix[3][3]);
}

TransformationMatrix TransformationMatrix::to2dTransform() const
{
    return TransformationMatrix(m_matrix[0][0], m_matrix[0][1], 0, m_matrix[0][3],
                                m_matrix[1][0], m_matrix[1][1], 0, m_matrix[1][3],
                                0, 0, 1, 0,
                                m_matrix[3][0], m_matrix[3][1], 0, m_matrix[3][3]);
}

auto TransformationMatrix::toColumnMajorFloatArray() const -> FloatMatrix4
{
    return { {
        float(m11()), float(m12()), float(m13()), float(m14()),
        float(m21()), float(m22()), float(m23()), float(m24()),
        float(m31()), float(m32()), float(m33()), float(m34()),
        float(m41()), float(m42()), float(m43()), float(m44()) } };
}

bool TransformationMatrix::isBackFaceVisible() const
{
    // Back-face visibility is determined by transforming the normal vector (0, 0, 1) and
    // checking the sign of the resulting z component. However, normals cannot be
    // transformed by the original matrix, they require being transformed by the
    // inverse-transpose.
    //
    // Since we know we will be using (0, 0, 1), and we only care about the z-component of
    // the transformed normal, then we only need the m33() element of the
    // inverse-transpose. Therefore we do not need the transpose.
    //
    // Additionally, if we only need the m33() element, we do not need to compute a full
    // inverse. Instead, knowing the inverse of a matrix is adjoint(matrix) / determinant,
    // we can simply compute the m33() of the adjoint (adjugate) matrix, without computing
    // the full adjoint.

    double determinant = WebCore::determinant4x4(m_matrix);

    // If the matrix is not invertible, then we assume its backface is not visible.
    if (!std::isnormal(determinant))
        return false;

    double cofactor33 = determinant3x3(m11(), m12(), m14(), m21(), m22(), m24(), m41(), m42(), m44());
    double zComponentOfTransformedNormal = cofactor33 / determinant;

    return zComponentOfTransformedNormal < 0;
}

TransformationMatrix TransformationMatrix::transpose() const
{
    TransformationMatrix transpose;
    transposeMatrix4(m_matrix, transpose.m_matrix);
    return transpose;
}

TextStream& operator<<(TextStream& ts, const TransformationMatrix& transform)
{
    TextStream::IndentScope indentScope(ts);
    ts << '\n';
    ts << indent << '[' << transform.m11() << ' ' << transform.m12() << ' ' << transform.m13() << ' ' << transform.m14() << "]\n"_s;
    ts << indent << '[' << transform.m21() << ' ' << transform.m22() << ' ' << transform.m23() << ' ' << transform.m24() << "]\n"_s;
    ts << indent << '[' << transform.m31() << ' ' << transform.m32() << ' ' << transform.m33() << ' ' << transform.m34() << "]\n"_s;
    ts << indent << '[' << transform.m41() << ' ' << transform.m42() << ' ' << transform.m43() << ' ' << transform.m44() << ']';
    return ts;
}

}
