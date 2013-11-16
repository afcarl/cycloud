#cython: boundscheck=False, wraparound=False

import cython
from cython.parallel import parallel, prange

cimport numpy as np

import numpy as np
import scipy.misc
from struct import pack, unpack, calcsize

def fitPlane(points):
    mean = points.mean(axis=0)
    uu,dd,vv = np.linalg.svd(points-mean)
    plane = np.zeros(4)
    plane[:3] = vv[0]
    plane[3] = -np.dot(vv[0], mean)
    return plane

def fitLine(points):
    mean = points.mean(axis=0)
    uu,dd,vv = np.linalg.svd(points-mean)
    line = np.zeros(6)
    line[:3] = mean
    line[3:] = vv[0]
    return line

@cython.cdivision(True)
cpdef registerDepthMap(np.float_t[:,:] unregisteredDepthMap,
                       np.uint8_t[:,:,:] rgbImage,
                       np.float_t[:,:] depthK=None,
                       np.float_t[:,:] rgbK=None,
                       np.float_t[:,:] H_RGBFromDepth=None):

    # Use the default value that Primesense uses for most sensors if no
    # calibration matrix is provided.
    if depthK is None:
        depthK_tmp = np.array([[570.34, 0, 320.0],
                            [0, 570.34, 240.0],
                            [0, 0, 1]])
        if unregisteredDepthMap.shape[1] != 640:
            scale = unregisteredDepthMap.shape[1] / 640.0
            depthK = depthK_tmp * scale
    if rgbK is None:
        rgbK_tmp = np.array([[540, 0, 320.0],
                         [0, 540, 240.0],
                         [0, 0, 1]])
        if rgbImage.shape[1] != 640:
            scale = rgbImage.shape[1] / 640.0
            rgbK = rgbK_tmp * scale
    # This default transform assumes that units are centimeters.
    if H_RGBFromDepth is None:
        H_RGBFromDepth = np.array([[1, 0, 0, 2.5],
                                   [0, 1, 0, 0],
                                   [0, 0, 1, 0],
                                   [0, 0, 0, 1]])

    cdef int unregisteredHeight = unregisteredDepthMap.shape[0]
    cdef int unregisteredWidth = unregisteredDepthMap.shape[1]

    cdef int registeredHeight = rgbImage.shape[0]
    cdef int registeredWidth = rgbImage.shape[1]

    cdef np.ndarray[np.float_t, ndim=2] registeredDepthMap 
    registeredDepthMap = np.zeros((registeredHeight, registeredWidth))
    cdef np.float_t[:,:] registeredDepthMap_view = registeredDepthMap

    cdef int u, v

    cdef np.float_t depth

    cdef np.ndarray[np.float_t, ndim=2] xyzDepth = np.empty((4,1))
    cdef np.ndarray[np.float_t, ndim=2] xyzRGB = np.empty((4,1))
    cdef np.float_t[:] xyzDepth_view = xyzDepth[:,0]
    cdef np.float_t[:] xyzRGB_view = xyzRGB[:,0]

    # Ensure that the last value is 1 (homogeneous coordinates)
    xyzDepth_view[3] = 1

    cdef np.float_t invDepthFx = 1.0 / depthK[0,0]
    cdef np.float_t invDepthFy = 1.0 / depthK[1,1]
    cdef np.float_t depthCx = depthK[0,2]
    cdef np.float_t depthCy = depthK[1,2]

    cdef np.float_t rgbFx = rgbK[0,0]
    cdef np.float_t rgbFy = rgbK[1,1]
    cdef np.float_t rgbCx = rgbK[0,2]
    cdef np.float_t rgbCy = rgbK[1,2]

    cdef np.float_t invRGB_Z
    cdef int uRGB, vRGB

    cdef np.float_t registeredDepth

    for v in range(unregisteredHeight):
      for u in range(unregisteredWidth):

            depth = unregisteredDepthMap[v,u]
            if depth == 0:
                continue

            xyzDepth_view[0] = ((u - depthCx) * depth) * invDepthFx
            xyzDepth_view[1] = ((v - depthCy) * depth) * invDepthFy
            xyzDepth_view[2] = depth

            xyzRGB_view[0] = (H_RGBFromDepth[0,0] * xyzDepth_view[0] +
                              H_RGBFromDepth[0,1] * xyzDepth_view[1] +
                              H_RGBFromDepth[0,2] * xyzDepth_view[2] +
                              H_RGBFromDepth[0,3])
            xyzRGB_view[1] = (H_RGBFromDepth[1,0] * xyzDepth_view[0] +
                              H_RGBFromDepth[1,1] * xyzDepth_view[1] +
                              H_RGBFromDepth[1,2] * xyzDepth_view[2] +
                              H_RGBFromDepth[1,3])
            xyzRGB_view[2] = (H_RGBFromDepth[2,0] * xyzDepth_view[0] +
                              H_RGBFromDepth[2,1] * xyzDepth_view[1] +
                              H_RGBFromDepth[2,2] * xyzDepth_view[2] +
                              H_RGBFromDepth[2,3])

            invRGB_Z  = 1.0 / xyzRGB_view[2]
            uRGB = int((rgbFx * xyzRGB_view[0]) * invRGB_Z + rgbCx + 0.5)
            vRGB = int((rgbFy * xyzRGB_view[1]) * invRGB_Z + rgbCy + 0.5)

            if (uRGB < 0 or uRGB >= registeredWidth) or (vRGB < 0 or vRGB >= registeredHeight):
                continue

            registeredDepth = xyzRGB_view[2]
            if registeredDepth > registeredDepthMap_view[vRGB,uRGB]:
                registeredDepthMap_view[vRGB,uRGB] = registeredDepth

    return registeredDepthMap

cpdef get3dPoints(np.float_t[:,:] K,
                  np.float_t[:,:] points2d,
                  np.float_t[:] depths):

    cdef np.float_t cx = K[0,2]
    cdef np.float_t cy = K[1,2]
    cdef np.float_t invFx = 1.0/K[0,0]
    cdef np.float_t invFy = 1.0/K[1,1]

    cdef np.float_t depth

    cdef np.ndarray[np.float_t,ndim=2] points
    points = np.empty((points2d.shape[0], 3), dtype=np.float)

    cdef int i

    for i in range(points.shape[0]):
        points[i,0] = (points2d[i,0] - cx) * depths[i] * invFx
        points[i,1] = (points2d[i,1] - cy) * depths[i] * invFy
        points[i,2] = depths[i]

    return points

cpdef unregisteredDepthMapToPointCloud(np.float_t[:,:] depthMap,
                                       np.float_t[:,:] depthK=None,
                                       organized=True):

    # Use the default value that Primesense uses for most sensors if no
    # calibration matrix is provided.
    if depthK is None:
        depthK_tmp = np.array([[570.34, 0, 320.0],
                            [0, 570.34, 240.0],
                            [0, 0, 1]])
        if depthMap.shape[1] != 640:
            scale = depthMap.shape[1] / 640.0
            depthK = depthK_tmp * scale

    cdef np.float_t depthCx = depthK[0,2]
    cdef np.float_t depthCy = depthK[1,2]
    cdef np.float_t depthInvFx = 1.0/depthK[0,0]
    cdef np.float_t depthInvFy = 1.0/depthK[1,1]

    cdef int height = depthMap.shape[0]
    cdef int width = depthMap.shape[1]
    cdef int u, v

    cdef np.float_t depth

    # Allocate empty ndarray. Fill in zeros in the same pass as when creating
    # the cloud.
    cdef np.ndarray[np.float_t,ndim=3] cloud
    if organized:
      cloud = np.empty((height, width, 3), dtype=np.float)
    else:
      cloud = np.empty((1, height*width, 3), dtype=np.float)

    cdef int row, col
    cdef int goodPointsCount = 0

    for v in range(height):
        for u in range(width):

            depth = depthMap[v,u]

            if organized:
              row = v
              col = u
            else:
              row = 0
              col = goodPointsCount

            if depth <= 0:
                if organized:
                    if depth <= 0:
                       cloud[row,col,0] = 0
                       cloud[row,col,1] = 0
                       cloud[row,col,2] = 0
                continue

            cloud[row,col,0] = (u - depthCx) * depth * depthInvFx
            cloud[row,col,1] = (v - depthCy) * depth * depthInvFy
            cloud[row,col,2] = depth

            if not organized:
              goodPointsCount += 1

    if not organized: 
      cloud = cloud[:,:goodPointsCount,:]
    return cloud

cpdef registeredDepthMapToPointCloud(np.float_t[:,:] depthMap,
                                     np.uint8_t[:,:,:] rgbImage,
                                     np.float_t[:,:] rgbK=None,
                                     organized=True):

    # Use the default value that Primesense uses for most sensors if no
    # calibration matrix is provided.
    if rgbK is None:
        rgbK_tmp = np.array([[540, 0, 320.0],
                         [0, 540, 240.0],
                         [0, 0, 1]])
        if rgbImage.shape[1] != 640:
            scale = rgbImage.shape[1] / 640.0
            rgbK = rgbK_tmp * scale

    cdef np.float_t rgbCx = rgbK[0,2]
    cdef np.float_t rgbCy = rgbK[1,2]
    cdef np.float_t invRGBFx = 1.0/rgbK[0,0]
    cdef np.float_t invRGBFy = 1.0/rgbK[1,1]

    cdef int height = depthMap.shape[0]
    cdef int width = depthMap.shape[1]
    cdef int u, v

    cdef np.ndarray[np.float_t,ndim=3] cloud

    if organized:
      cloud = np.empty((height, width, 6), dtype=np.float)
    else:
      cloud = np.empty((1, height*width, 6), dtype=np.float)

    cdef int goodPointsCount = 0
    cdef int row, col
    for v in range(height):
        for u in range(width):

            depth = depthMap[v,u]

            if organized:
              row = v
              col = u
            else:
              row = 0
              col = goodPointsCount

            if depth <= 0:
                if organized:
                    if depth <= 0:
                       cloud[row,col,0] = 0
                       cloud[row,col,1] = 0
                       cloud[row,col,2] = 0
                       cloud[row,col,3] = 0
                       cloud[row,col,4] = 0
                       cloud[row,col,5] = 0
                continue

            cloud[row,col,0] = (u - rgbCx) * depth * invRGBFx
            cloud[row,col,1] = (v - rgbCy) * depth * invRGBFy
            cloud[row,col,2] = depth
            cloud[row,col,3] = rgbImage[v,u,0]
            cloud[row,col,4] = rgbImage[v,u,1]
            cloud[row,col,5] = rgbImage[v,u,2]
            if not organized:
              goodPointsCount += 1

    if not organized: 
      cloud = cloud[:,:goodPointsCount,:]
    return cloud

cpdef downsampleImage(np.ndarray[np.uint8_t, ndim=3] rgbImage,
                      np.ndarray[np.float_t, ndim=2] rgbK):
    supportedHeights = [960, 1024]
    supportedWidths = [1280]
    cdef int height = rgbImage.shape[0]
    cdef int width = rgbImage.shape[1]
    if height not in supportedHeights and width not in supportedWidths:
        print "Non supported image size ({0}, {1})".format(height, width)
        raise

    scale = width/640.0
    shift = 0
    if height == 1024:
        shift = 30
   
    cdef np.ndarray[np.float_t, ndim=2] rgbKNew
    rgbKNew = rgbK.copy()
    rgbKNew[1, 2] = rgbK[1, 2] - shift
    rgbKNew = rgbKNew/scale
    rgbKNew[2, 2] = 1

    cdef np.ndarray[np.uint8_t, ndim=3] downsampImage
    downsampImage = scipy.misc.imresize(rgbImage[shift:960+shift, :, :], (480, 640)) 

    return (downsampImage, rgbKNew)
    


def transformCloud(cloud, H, inplace=False):
    if cloud.shape[0] != 1:
        raise Exception("transformCloud for organized clouds not yet implemented.")

    H_cloud = np.empty((cloud.shape[1], 4))
    H_cloud[:, :3] = cloud[0,:,:3]
    H_cloud[:, 3] = 1
    transformed_H_cloud = np.dot(H,H_cloud.T).T
    if inplace:
        cloud[0,:,:3] = transformed_H_cloud[:,:3]
    else:
        cloud = np.copy(cloud)
        cloud[0,:,:3] = transformed_H_cloud[:,:3]
    return cloud

cpdef projectPoints(np.float_t[:,:] K, np.float_t[:,:] points):

    cdef np.ndarray[np.float_t, ndim=2] points2d
    points2d = np.empty((points.shape[0],2), dtype=np.float)

    cdef float fx = K[0,0]
    cdef float fy = K[1,1]
    cdef float cx = K[0,2]
    cdef float cy = K[1,2]

    cdef int i

    cdef float depth

    for i in range(points2d.shape[0]):
        depth = points2d[i,2]
        points2d[i,0] = points[i,0] * fx / depth + cx
        points2d[i,1] = points[i,1] * fy / depth + cy

    return points2d

def depthMapToImage(image):
    return np.uint8(image / (np.max(image)*1.0/255))

# TODO sanity check speed / read write
def writePCD(pointCloud, filename, ascii=False):
    if len(pointCloud.shape) != 3:
      print "Expected pointCloud to have 3 dimensions. Got %d instead" % len(pointCloud.shape)
      return
    with open(filename, 'w') as f:
        height = pointCloud.shape[0]
        width = pointCloud.shape[1]
        f.write("# .PCD v.7 - Point Cloud Data file format\n")
        f.write("VERSION .7\n")
        if pointCloud.shape[2] == 3:
            f.write("FIELDS x y z\n")
            f.write("SIZE 4 4 4\n")
            f.write("TYPE F F F\n")
            f.write("COUNT 1 1 1\n")
        else:
            f.write("FIELDS x y z rgb\n")
            f.write("SIZE 4 4 4 4\n")
            f.write("TYPE F F F F\n")
            f.write("COUNT 1 1 1 1\n")
        f.write("WIDTH %d\n" % width)
        f.write("HEIGHT %d\n" % height)
        f.write("VIEWPOINT 0 0 0 1 0 0 0\n")
        f.write("POINTS %d\n" % (height * width))
        if ascii:
          f.write("DATA ascii\n")
          for row in range(height):
            for col in range(width):
                if pointCloud.shape[2] == 3:
                    f.write("%f %f %f\n" % tuple(pointCloud[row, col, :]))
                else:
                    f.write("%f %f %f" % tuple(pointCloud[row, col, :3]))
                    r = int(pointCloud[row, col, 3])
                    g = int(pointCloud[row, col, 4])
                    b = int(pointCloud[row, col, 5])
                    rgb_int = (r << 16) | (g << 8) | b
                    packed = pack('i', rgb_int)
                    rgb = unpack('f', packed)[0]
                    f.write(" %.12e\n" % rgb)
        else:
          f.write("DATA binary\n")
          if pointCloud.shape[2] == 6:
              # These are written as bgr because rgb is interpreted as a single
              # little-endian float.
              dt = np.dtype([('x', np.float32),
                             ('y', np.float32),
                             ('z', np.float32),
                             ('b', np.uint8),
                             ('g', np.uint8),
                             ('r', np.uint8),
                             ('I', np.uint8)])
              pointCloud_tmp = np.zeros((height*width, 1), dtype=dt)
              for i, k in enumerate(['x', 'y', 'z', 'r', 'g', 'b']):
                  pointCloud_tmp[k] = pointCloud[:, :, i].reshape((height*width, 1))
              pointCloud_tmp.tofile(f)
          else:
              dt = np.dtype([('x', np.float32),
                             ('y', np.float32),
                             ('z', np.float32),
                             ('I', np.uint8)])
              pointCloud_tmp = np.zeros((height*width, 1), dtype=dt)
              for i, k in enumerate(['x', 'y', 'z']):
                  pointCloud_tmp[k] = pointCloud[:, :, i].reshape((height*width, 1))
              pointCloud_tmp.tofile(f)

# TODO sanity check speed / read write
def readPCD(filename):
    with open(filename, 'r') as f:
        #"# .PCD v.7 - Point Cloud Data file format\n"
        f.readline()

        #"VERSION .7\n"
        f.readline()

        # "FIELDS x y z\n"
        fields = f.readline().strip().split()[1:]

        if len(fields) == 3:
            rgb = False
        elif len(fields) == 4:
            rgb = True
        else:
            raise Exception("Unsupported fields: %s" % str(fields))

        #"SIZE 4 4 4\n"
        sizes = [int(x) for x in f.readline().strip().split()[1:]]
        pointSize = np.sum(sizes)

        #"TYPE F F F\n"
        types = f.readline().strip().split()[1:]

        #"COUNT 1 1 1\n"
        counts = [int(x) for x in f.readline().strip().split()[1:]]

        #"WIDTH %d\n" % width
        width = int(f.readline().strip().split()[1])

        #"HEIGHT %d\n" % height
        height = int(f.readline().strip().split()[1])

        #"VIEWPOINT 0 0 0 1 0 0 0\n"
        viewpoint = np.array(f.readline().strip().split()[1:])

        #"POINTS %d\n" % height * width
        points = int(f.readline().strip().split()[1])

        #"DATA ascii\n"
        format = f.readline().strip().split()[1]
        ascii = format == 'ascii'

        if rgb:
            pointCloud = np.empty((height, width, 6))
        else:
            pointCloud = np.empty((height, width, 3))

        for row in range(height):
            for col in range(width):
                if ascii:
                    data = [float(x) for x in f.readline().strip().split()]
                else:
                    data = unpack('ffff', f.read(pointSize))

                pointCloud[row, col, 0] = data[0]
                pointCloud[row, col, 1] = data[1]
                pointCloud[row, col, 2] = data[2]

                if rgb:
                    rgb_float = data[3]
                    packed = pack('f', rgb_float)
                    rgb_int = unpack('i', packed)[0]
                    r = rgb_int >> 16 & 0x0000ff
                    g = rgb_int >> 8 & 0x0000ff
                    b = rgb_int & 0x0000ff
                    pointCloud[row, col, 3] = r
                    pointCloud[row, col, 4] = g
                    pointCloud[row, col, 5] = b

        return pointCloud

